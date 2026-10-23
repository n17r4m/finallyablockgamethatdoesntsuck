extends Node2D
## Drives the RollbackSession from the wall clock. Boards are drawn by renderers
## that read BoardView only, so swapping in 3D touches nothing here but _ready.


var session: RollbackSession
var _offline := false
var _ended := ""
var _acc := 0 # tick-units * 1e6, so no float drift
var _last_usec := 0
var _views: Array[BoardRenderer2D] = []


func _ready() -> void:
	_offline = Net.remote_id == 0
	var delay: int = Config.get_value("net", "input_delay_frames") * SimConst.TICKS_PER_FRAME
	session = RollbackSession.new(Net.match_seed, Net.local_idx, delay, _offline)
	session.desynced.connect(_on_desynced)
	print("match start seed=%d idx=%d %s" % [Net.match_seed, Net.local_idx, "offline" if _offline else "online"])
	if not _offline:
		session.outgoing.connect(Net.send)
		Net.packet.connect(session.receive)
		Net.opponent_left.connect(_on_opponent_left)
	for p in 2:
		var v := BoardRenderer2D.new()
		v.position = Vector2(280 + p * 480, 120)
		v.label = "YOU" if p == Net.local_idx else ("—" if _offline else "THEM")
		add_child(v)
		_views.append(v)
	_last_usec = Time.get_ticks_usec()


func _exit_tree() -> void:
	if Net.packet.is_connected(session.receive):
		Net.packet.disconnect(session.receive)


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("ui_cancel"):
		Net.leave()
		Scenes.goto(Scenes.TITLE)
		return
	var now := Time.get_ticks_usec()
	_acc += (now - _last_usec) * SimConst.TICK_HZ
	_last_usec = now
	var due := mini(_acc / 1_000_000, SimConst.TICK_HZ / 10)
	# Ticks lost to a stall are dropped, not banked: the side that's ahead slows down.
	_acc = mini(_acc - due * 1_000_000, 1_000_000)
	if _ended == "":
		session.set_local_input(Controls.sample())
		session.advance(due)
	for p in 2:
		_views[p].board = session.state.boards[p]
	queue_redraw()


func _draw() -> void:
	var font := ThemeDB.fallback_font
	var hud := "tick %d   %d Hz" % [session.state.tick, SimConst.TICK_HZ]
	if not _offline:
		hud += "   rtt %d ms   rollbacks %d   resim %d   stalls %d" % [Net.rtt_ms, session.stats.rollbacks,
				session.stats.resim, session.stats.stalls]
	draw_string(font, Vector2(20, 30), hud, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 1, 1, 0.6))
	draw_string(font, Vector2(20, 700), "arrows/WASD move · space/X swap · C/shift raise · esc leave",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 1, 1, 0.4))
	if _ended != "":
		draw_string(font, Vector2(0, 360), _ended, HORIZONTAL_ALIGNMENT_CENTER, 1280, 28)


func _on_desynced(tick: int) -> void:
	_ended = "DESYNC at tick %d — this is a bug, please report" % tick
	push_error(_ended)


func _on_opponent_left() -> void:
	_ended = "Opponent left — esc for title"


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if session and not _offline:
			print("match end tick=%d stats=%s rtt=%d" % [session.state.tick, session.stats, Net.rtt_ms])
