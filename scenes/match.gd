extends Node2D
## Drives the RollbackSession from the wall clock and runs the match flow
## (countdown -> play -> result -> rematch). Boards are drawn by renderers that
## read BoardView only; config video/renderer picks "3d" (default) or "2d".

var session: RollbackSession
var _offline := false
var _ended := ""
var _rematch_sent := false
var _acc := 0 # tick-units * 1e6, so no float drift
var _last_usec := 0
var _views: Array[Node] = [] # BoardRenderer3D or BoardRenderer2D, indexed by board


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
	if Config.get_value("video", "renderer") == "2d":
		_build_2d()
	else:
		_build_3d()
	_last_usec = Time.get_ticks_usec()


func _build_3d() -> void:
	var world := Node3D.new()
	add_child(world)
	var cam := Camera3D.new()
	cam.position = Vector3(0, -0.4, 20.5)
	cam.fov = 42
	world.add_child(cam)
	cam.make_current()
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, -30, 0)
	world.add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = RenderingServer.get_default_clear_color()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.55, 0.65)
	env.ambient_light_energy = 0.7
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)
	for p in 2:
		var v := BoardRenderer3D.new()
		v.position = Vector3(0.0 if _offline else -6.5 + 13.0 * p, 0, 0)
		v.label = _label(p)
		v.visible = not (_offline and p == 1)
		world.add_child(v)
		_views.append(v)


func _build_2d() -> void:
	for p in 2:
		var v := BoardRenderer2D.new()
		v.position = Vector2(520.0 if _offline else 280.0 + p * 480.0, 120)
		v.label = _label(p)
		v.visible = not (_offline and p == 1)
		add_child(v)
		_views.append(v)


func _label(p: int) -> String:
	return "YOU" if p == Net.local_idx else "THEM"


func _exit_tree() -> void:
	if Net.packet.is_connected(session.receive):
		Net.packet.disconnect(session.receive)


func _process(delta: float) -> void:
	if Input.is_action_just_pressed("ui_cancel"):
		Net.leave()
		Scenes.goto(Scenes.TITLE)
		return
	var now := Time.get_ticks_usec()
	# Movie Maker (--write-movie) renders slower than real time; follow its fixed delta
	# so recorded trailers play at true speed.
	var elapsed := int(delta * 1_000_000) if OS.has_feature("movie") else now - _last_usec
	_acc += elapsed * SimConst.TICK_HZ
	_last_usec = now
	var due := mini(_acc / 1_000_000, SimConst.TICK_HZ / 10)
	# Ticks lost to a stall are dropped, not banked: the side that's ahead slows down.
	_acc = mini(_acc - due * 1_000_000, 1_000_000)
	if _ended == "":
		session.set_local_input(Controls.sample())
		session.advance(due)
	if session.state.winner != -1 and not _rematch_sent and Input.is_action_just_pressed("swap"):
		_rematch_sent = true
		Net.request_rematch()
	for p in 2:
		_views[p].board = session.state.boards[p]
	queue_redraw()


func _draw() -> void:
	var font := ThemeDB.fallback_font
	var s := session.state
	var hud := "%d Hz" % SimConst.TICK_HZ
	if not _offline:
		hud += "   rtt %d ms   rollbacks %d   resim %d   stalls %d" % [Net.rtt_ms, session.stats.rollbacks,
				session.stats.resim, session.stats.stalls]
	draw_string(font, Vector2(20, 30), hud, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 1, 1, 0.5))
	draw_string(font, Vector2(20, 700), "arrows/WASD move · space/X swap · C/shift raise · esc leave",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 1, 1, 0.4))

	var big := ""
	var small := ""
	if s.tick < SimConst.COUNTDOWN_TICKS:
		big = str(ceili(float(SimConst.COUNTDOWN_TICKS - s.tick) / SimConst.TICK_HZ))
	elif s.tick < SimConst.COUNTDOWN_TICKS + SimConst.TICK_HZ / 2:
		big = "GO!"
	if s.winner != -1:
		if _offline:
			big = "GAME OVER"
			small = "score %d" % s.boards[0].score
		else:
			big = "DRAW" if s.winner == 2 else ("YOU WIN" if s.winner == session.local_idx else "YOU LOSE")
		small += ("   waiting for opponent…" if _rematch_sent and not _offline
				else "   swap for %s · esc for title" % ("retry" if _offline else "rematch"))
	if _ended != "":
		big = ""
		small = _ended
	if big != "":
		draw_string_outline(font, Vector2(0, 360), big, HORIZONTAL_ALIGNMENT_CENTER, 1280, 72, 12, Color.BLACK)
		draw_string(font, Vector2(0, 360), big, HORIZONTAL_ALIGNMENT_CENTER, 1280, 72)
	if small != "":
		draw_string_outline(font, Vector2(0, 410), small, HORIZONTAL_ALIGNMENT_CENTER, 1280, 24, 8, Color.BLACK)
		draw_string(font, Vector2(0, 410), small, HORIZONTAL_ALIGNMENT_CENTER, 1280, 24)


func _on_desynced(tick: int) -> void:
	_ended = "DESYNC at tick %d — this is a bug, please report" % tick
	push_error(_ended)


func _on_opponent_left() -> void:
	_ended = "Opponent left — esc for title"


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if session and not _offline:
			print("match end tick=%d stats=%s rtt=%d" % [session.state.tick, session.stats, Net.rtt_ms])
