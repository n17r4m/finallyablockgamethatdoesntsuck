extends Node2D
## Drives the RollbackSession from the wall clock and draws it. Placeholder art
## via _draw — the sim never touches nodes, so real visuals can replace this freely.

const CELL := 40
const PALETTE: Array[Color] = [Color.BLACK, Color("e04f5f"), Color("4fc46a"), Color("4f8fe0"),
		Color("e8c547"), Color("a35fd6")]

var session: RollbackSession
var _offline := false
var _ended := ""
var _acc := 0 # tick-units * 1e6, so no float drift
var _last_usec := 0


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
	queue_redraw()


func _draw() -> void:
	var font := ThemeDB.fallback_font
	var s := session.state
	for p in 2:
		var b := s.boards[p]
		var origin := Vector2(280 + p * 480, 140)
		var rise_px := float(b.rise) / SimConst.ROW_UNITS * CELL
		draw_rect(Rect2(origin, Vector2(SimConst.W, SimConst.H) * CELL), Color(0.08, 0.08, 0.12))
		for y in SimConst.H:
			for x in SimConst.W:
				var i := y * SimConst.W + x
				if b.cells[i] == 0:
					continue
				var r := Rect2(origin + Vector2(x * CELL, y * CELL - rise_px), Vector2(CELL, CELL)).grow(-2)
				if b.gid[i] != 0:
					# Bridge the gap to the right neighbour so a slab reads as one piece.
					if x < SimConst.W - 1 and b.gid[i + 1] == b.gid[i]:
						r.size.x += 4
					draw_rect(r, Color("8a8f9e"))
					continue
				var c := PALETTE[b.cells[i]]
				if b.clear_t[i] > 0 and (b.clear_t[i] / 54) % 2 == 0:
					c = Color.WHITE
				draw_rect(r, c)
		var cur := Rect2(origin + Vector2(b.cursor_x * CELL, b.cursor_y * CELL - rise_px), Vector2(CELL * 2, CELL))
		draw_rect(cur, Color.WHITE, false, 3.0)
		var who := "YOU" if p == session.local_idx else ("—" if _offline else "THEM")
		draw_string(font, origin + Vector2(0, -16), "%s   %d%s" % [who, b.score, "   TOPPED OUT" if b.lost else ""],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 20)
		if not b.gar_q.is_empty():
			draw_string(font, origin + Vector2(0, -40), "incoming " + " ".join(Array(b.gar_q).map(str)),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("8a8f9e"))
	var hud := "tick %d   %d Hz" % [s.tick, SimConst.TICK_HZ]
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
