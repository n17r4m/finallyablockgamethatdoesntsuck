extends Node2D
## Drives the RollbackSession from the wall clock and runs the match flow
## (countdown -> play -> result -> rematch). Boards are drawn by renderers that
## read BoardView only; config video/renderer picks "3d" (default) or "2d".

const REPLAY_DIR := "user://replays"
const HINT_DP := 12 # font size in dp, for reading at arm's length on a phone
const HINT_MIN := 16 # font size in project units, for a desktop window
const HINT_PAD_CELLS := 0.3 # clear of the board, whose blocks stand in front of its plane
const HINT_ROWS := 4.5 # a narrow screen's hint: the empty top of your well, above the countdown
const EDGE_UNITS := 20.0
const RETRY_TAP_DELAY_MS := 1000 # a player still dragging when the game ends isn't asking to retry
const LEAVE_SIZE_DP := Vector2(72, 48) # 48 is the usual minimum for a finger
const LEAVE_MARGIN_DP := 8.0
const LEAVE_FONT_DP := 14.0
const LEAVE_CONFIRM_MS := 3000
const NOTICE_MS := 8000 # how long a message from the server's operator stays up
const CAM_Y := 0.3
const CAM_Z := 20.5
const CAM_FOV := 42.0
## Narrower than this and side-by-side boards at the normal view don't fit: 19.3 cells across
## out of the 15.74 the camera sees top to bottom. Then your board is sized for fingers, with
## the opponent's small beside it. Two equal boards would leave cells of 20 dp on a phone.
const SIDE_BY_SIDE_ASPECT := 1.24
const OPPONENT_SCALE := 0.25
# With more than two boards, the others go small in a grid beside yours, as large as fits.
const OTHERS_MAX_SCALE := 0.5
const OTHERS_MIN_SCALE := 0.13
const NAME_ROOM := 2.4 # under a small board: its name and what's coming, in cells of your board
const TEAM_GAP := 0.8 # between teams, when the small boards are all in one row
# The narrow layout, in cells of your board.
const WELL := SimConst.W + 0.3
const GAP := 0.2
const EDGE := 0.1
const ABOVE_BOARD := 1.5 # title and incoming garbage
const BELOW_BOARD := 1.15 # the rising row
const HINT_ROOM := 1.0 # under the board, if the screen has it, clear of the phone's own gestures

var session: RollbackSession
var _offline := false
var _ended := ""
var _opponent_gone := false
var _left := false
var _rematch_sent := false
var _acc := 0 # tick-units * 1e6, so no float drift
var _last_usec := 0
var _views: Array[Node] = [] # BoardRenderer3D or BoardRenderer2D, indexed by board
var _cpu: CpuPlayer # offline opponent on board 1
var _cpus: Array[CpuPlayer] = [] # offline, per seat: who plays it, null for you
var _pilot: CpuPlayer # demo mode: a CPU on your board too
var _over_msec := -1 # when the game ended
var _cam: Camera3D
var _leave_button: Button
var _leave_asked_msec := -1 # when a tap asked to leave a running game, waiting for the second
var _notice := ""
var _notice_msec := -1
var _sfx: Sfx


func _ready() -> void:
	_offline = Net.remote_id == 0
	# Input delay only hides network lag from rollback, so offline play has none.
	var delay: int = 0 if _offline else Config.get_value("net", "input_delay_frames") * SimConst.TICKS_PER_FRAME
	var solo := _offline and Net.cpu_name == ""
	session = RollbackSession.new(Net.match_seed, Net.local_idx, delay, _offline, solo, Config.get_value("sim", "backend"), Net.match_rules, Net.match_teams)
	if _offline and not solo:
		_cpus.resize(session.seats())
		var teams := session.state.teams
		# The first opponent is the one you picked; the rest, teammates included, take the other
		# personalities in turn, so no two boards play alike.
		var names: Array = CpuPlayer.OPPONENTS.keys()
		var order: Array = [Net.cpu_name] + names.filter(func(n: String) -> bool: return n != Net.cpu_name)
		var next_name := 1
		var picked_taken := false
		for p in session.seats():
			if p == Net.local_idx:
				continue
			var name: String
			if teams[p] != teams[Net.local_idx] and not picked_taken:
				name = Net.cpu_name
				picked_taken = true
			else:
				name = order[next_name % order.size()]
				next_name += 1
			_cpus[p] = CpuPlayer.opponent(name, Net.cpu_level, Net.match_seed + p)
		_cpu = _cpus[1 - Net.local_idx] if session.seats() == 2 else null
		if Net.demo:
			_pilot = CpuPlayer.opponent("Overmind", Net.cpu_level, Net.match_seed + 1)
	session.desynced.connect(_on_desynced)
	print("match start seed=%d idx=%d %s delay=%d rules=%s teams=%s" % [Net.match_seed, Net.local_idx,
			"offline" if _offline else "online", delay, _rules_name(), session.state.teams])
	if not _offline:
		session.outgoing.connect(Net.send)
		Net.packet.connect(session.receive)
		Net.opponent_left.connect(_on_opponent_left)
		Net.notice.connect(_on_notice)
	if Config.get_value("video", "renderer") == "2d":
		_build_2d()
	else:
		_build_3d()
	_layout()
	get_viewport().size_changed.connect(_layout) # a phone can turn at any time
	Controls.reset_touch()
	Controls.input_is_delayed = delay > 0
	if not _pilot:
		Controls.board_mapper = _views[Net.local_idx].screen_to_cell
	_sfx = Sfx.new()
	_sfx.local_idx = Net.local_idx
	add_child(_sfx)
	_build_leave_button()
	Scenes.back_pressed.connect(_ask_to_leave)
	_last_usec = Time.get_ticks_usec()


## Being a Control, it takes its touches before the board gestures and tap-to-retry can see them.
func _build_leave_button() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_leave_button = Button.new()
	_leave_button.text = "Leave"
	_leave_button.focus_mode = Control.FOCUS_NONE # or space, a swap key, would press it
	_leave_button.modulate.a = 0.7
	_leave_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_leave_button.pressed.connect(_ask_to_leave)
	layer.add_child(_leave_button)
	get_window().size_changed.connect(_fit_leave_button)
	_fit_leave_button()


func _fit_leave_button() -> void:
	var dp := Controls.dp_scale()
	_leave_button.add_theme_font_size_override("font_size", int(LEAVE_FONT_DP * dp))
	_leave_button.offset_left = -(LEAVE_MARGIN_DP + LEAVE_SIZE_DP.x) * dp
	_leave_button.offset_right = -LEAVE_MARGIN_DP * dp
	_leave_button.offset_top = LEAVE_MARGIN_DP * dp
	_leave_button.offset_bottom = (LEAVE_MARGIN_DP + LEAVE_SIZE_DP.y) * dp


## The button, leave's key or pad button, and Android's back. A stray press shouldn't throw away
## a game still being played, so that takes a second one; there's nothing to lose once it's over.
func _ask_to_leave() -> void:
	if _ended != "" or _opponent_gone or session.state.winner != -1 or _pilot or _leave_asked_msec != -1:
		_leave()
		return
	_leave_asked_msec = Time.get_ticks_msec()
	_leave_button.text = "Sure?"


func _leave() -> void:
	_left = true
	Net.leave()
	Scenes.goto(Scenes.TITLE)


func _rules_name() -> String:
	return "Rust" if session.state is RustState else "GDScript"


func _build_3d() -> void:
	var world := Node3D.new()
	add_child(world)
	_cam = Camera3D.new()
	_cam.fov = CAM_FOV
	world.add_child(_cam)
	_cam.make_current()
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
	for p in session.seats():
		var v := BoardRenderer3D.new()
		v.label = _label(p)
		v.visible = not (_solo() and p == 1)
		world.add_child(v)
		_views.append(v)


func _build_2d() -> void:
	for p in session.seats():
		var v := BoardRenderer2D.new()
		v.label = _label(p)
		v.visible = not (_solo() and p == 1)
		add_child(v)
		_views.append(v)


func _layout() -> void:
	var view := get_viewport_rect().size
	if _cam:
		_layout_3d(view)
	else:
		_layout_2d(view)


func _narrow(view: Vector2) -> bool:
	return view.x / view.y < SIDE_BY_SIDE_ASPECT


## How wide the narrow layout is, in cells of your board.
func _narrow_width() -> float:
	return WELL + 2 * EDGE + (0.0 if _solo() else GAP + WELL * OPPONENT_SCALE)


func _narrow_height() -> float:
	return ABOVE_BOARD + SimConst.H + BELOW_BOARD + 2 * EDGE


## Everyone but you, in the order they're laid out: your team first, then each other team.
func _others() -> Array[int]:
	var me := Net.local_idx
	var teams := session.state.teams
	var out: Array[int] = []
	for p in teams.size():
		if p != me and teams[p] == teams[me]:
			out.append(p)
	for t in session.state.team_count:
		if t != teams[me]:
			for p in teams.size():
				if teams[p] == t:
					out.append(p)
	return out


## For more than two boards: how many columns the small boards take, and their scale. Picks
## whatever leaves your board biggest on this screen, then the biggest small boards.
func _grid(view: Vector2) -> Vector2:
	var k := session.seats() - 1
	var best := Vector2(1, OTHERS_MIN_SCALE)
	var best_cell := -1.0
	for cols in range(1, k + 1):
		var rows := ceili(float(k) / cols)
		var fit := ((SimConst.H + BELOW_BOARD) / rows - NAME_ROOM - GAP) / (SimConst.H + BELOW_BOARD)
		var s := minf(OTHERS_MAX_SCALE, fit)
		if s < OTHERS_MIN_SCALE:
			continue
		var cell := minf(view.x / _grid_width(Vector2(cols, s)), view.y / _narrow_height())
		if cell > best_cell + 0.01 or (absf(cell - best_cell) <= 0.01 and s > best.y):
			best = Vector2(cols, s)
			best_cell = cell
	return best


func _grid_width(grid: Vector2) -> float:
	var cols := int(grid.x)
	return WELL + 2 * EDGE + cols * (GAP + WELL * grid.y) + _team_gaps(cols, session.seats() - 1) * TEAM_GAP


## How many team gaps come before small board i, when they're all in one row: none otherwise.
func _team_gaps(cols: int, i: int) -> int:
	if cols < session.seats() - 1:
		return 0
	var others := _others()
	var teams := session.state.teams
	var gaps := 0
	var before := Net.local_idx
	for k in mini(i + 1, others.size()):
		if teams[others[k]] != teams[before]:
			gaps += 1
		before = others[k]
	return gaps


## Where small board i sits, in cells from your well's top left: its well's top left.
func _grid_at(i: int, grid: Vector2) -> Vector2:
	var cols := int(grid.x)
	var s := grid.y
	return Vector2(WELL + GAP + (i % cols) * (WELL * s + GAP) + _team_gaps(cols, i) * TEAM_GAP,
			(i / cols) * ((SimConst.H + BELOW_BOARD) * s + NAME_ROOM + GAP))


func _layout_3d(view: Vector2) -> void:
	if session.seats() > 2:
		_layout_3d_many(view)
		return
	if not _narrow(view):
		_cam.position = Vector3(0, CAM_Y, CAM_Z)
		for p in 2:
			_views[p].arrange(Vector3(0.0 if _solo() else -6.5 + 13.0 * p, 0, 0), 1.0)
		return
	var seen := maxf(_narrow_height(), _narrow_width() * view.y / view.x) # cells top to bottom
	var spare := seen - _narrow_height()
	var bottom := -SimConst.H / 2.0 - BELOW_BOARD - EDGE - minf(spare / 2.0, HINT_ROOM)
	_cam.position = Vector3(0, bottom + seen / 2.0, seen / 2.0 / tan(deg_to_rad(CAM_FOV / 2.0)))
	var me := Net.local_idx
	var left := -_narrow_width() / 2.0 + EDGE
	_views[me].arrange(Vector3(left + WELL / 2.0, 0, 0), 1.0)
	var them_x := left + WELL + GAP + WELL * OPPONENT_SCALE / 2.0
	var them_y := SimConst.H / 2.0 * (1.0 - OPPONENT_SCALE)
	_views[1 - me].arrange(Vector3(them_x, them_y, 0), OPPONENT_SCALE, true)


func _layout_3d_many(view: Vector2) -> void:
	var grid := _grid(view)
	var width := _grid_width(grid)
	var seen := maxf(_narrow_height(), width * view.y / view.x) # cells top to bottom
	var spare := seen - _narrow_height()
	var bottom := -SimConst.H / 2.0 - BELOW_BOARD - EDGE - minf(spare / 2.0, HINT_ROOM)
	_cam.position = Vector3(0, bottom + seen / 2.0, seen / 2.0 / tan(deg_to_rad(CAM_FOV / 2.0)))
	var left := -width / 2.0 + EDGE
	var top := SimConst.H / 2.0
	_views[Net.local_idx].arrange(Vector3(left + WELL / 2.0, 0, 0), 1.0)
	var others := _others()
	for i in others.size():
		var at := _grid_at(i, grid)
		var s := grid.y
		_views[others[i]].arrange(Vector3(left + at.x + WELL * s / 2.0, top - at.y - SimConst.H * s / 2.0, 0), s, true)


func _layout_2d(view: Vector2) -> void:
	if session.seats() > 2:
		_layout_2d_many(view)
		return
	if not _narrow(view):
		# Boards keep their place on a 1280 wide screen, and stay centred on a wider one.
		var inset := (view.x - 1280.0) / 2.0
		for p in 2:
			_views[p].position = Vector2(inset + (520.0 if _solo() else 280.0 + p * 480.0), 120)
			_views[p].scale = Vector2.ONE
			_views[p].text_scale = 1.0
			_views[p].compact = false
		return
	var cell := minf(view.x / _narrow_width(), view.y / _narrow_height())
	var unit := cell / BoardRenderer2D.CELL
	var dp := Controls.dp_scale()
	var spare := view.y - _narrow_height() * cell
	var top := view.y - (BELOW_BOARD + EDGE + SimConst.H) * cell - minf(spare / 2.0, HINT_ROOM * cell)
	var left := (view.x - (_narrow_width() - 2 * EDGE) * cell) / 2.0
	var mine: BoardRenderer2D = _views[Net.local_idx]
	mine.position = Vector2(left + 0.15 * cell, top)
	mine.scale = Vector2.ONE * unit
	mine.text_scale = 17.0 * dp / (20.0 * unit)
	mine.compact = false
	var theirs: BoardRenderer2D = _views[1 - Net.local_idx]
	theirs.position = Vector2(left + (WELL + GAP + 0.15 * OPPONENT_SCALE) * cell, top)
	theirs.scale = Vector2.ONE * unit * OPPONENT_SCALE
	theirs.text_scale = 13.0 * dp / (20.0 * unit * OPPONENT_SCALE)
	theirs.compact = true


func _layout_2d_many(view: Vector2) -> void:
	var grid := _grid(view)
	var s := grid.y
	var width := _grid_width(grid)
	var cell := minf(view.x / width, view.y / _narrow_height())
	var unit := cell / BoardRenderer2D.CELL
	var dp := Controls.dp_scale()
	var spare := view.y - _narrow_height() * cell
	var top := view.y - (BELOW_BOARD + EDGE + SimConst.H) * cell - minf(spare / 2.0, HINT_ROOM * cell)
	var left := (view.x - (width - 2 * EDGE) * cell) / 2.0
	var mine: BoardRenderer2D = _views[Net.local_idx]
	mine.position = Vector2(left + 0.15 * cell, top)
	mine.scale = Vector2.ONE * unit
	mine.text_scale = 17.0 * dp / (20.0 * unit)
	mine.compact = false
	var others := _others()
	for i in others.size():
		var v: BoardRenderer2D = _views[others[i]]
		var at := _grid_at(i, grid)
		v.position = Vector2(left + (at.x + 0.15 * s) * cell, top + at.y * cell)
		v.scale = Vector2.ONE * unit * s
		v.text_scale = 13.0 * dp / (20.0 * unit * s)
		v.compact = true


func _solo() -> bool:
	return session.state.solo


func _label(p: int) -> String:
	if p == Net.local_idx:
		return "Overmind (%s)" % Net.cpu_level if _pilot else "YOU"
	var ally := session.seats() > 2 and session.state.teams[p] == session.state.teams[Net.local_idx]
	if not _cpus.is_empty() and _cpus[p]:
		if session.seats() > 2:
			return ("ALLY %s" if ally else "%s") % _cpus[p].name
		return "%s (%s)" % [Net.cpu_name, Net.cpu_level]
	var name := Net.seat_names[p].to_upper() if p < Net.seat_names.size() else ""
	if session.seats() > 2:
		if name == "":
			return "ALLY" if ally else "THEM"
		return ("ALLY %s" if ally else "%s") % name
	return name if name != "" else "THEM"


func _exit_tree() -> void:
	_save_replay()
	Controls.board_mapper = Callable()
	Controls.reset_touch()
	if Net.packet.is_connected(session.receive):
		Net.packet.disconnect(session.receive)


func _process(delta: float) -> void:
	if Input.is_action_just_pressed("leave"):
		_ask_to_leave()
		if _left:
			return
	if _leave_asked_msec != -1 and Time.get_ticks_msec() - _leave_asked_msec >= LEAVE_CONFIRM_MS:
		_leave_asked_msec = -1
		_leave_button.text = "Leave"
	var now := Time.get_ticks_usec()
	# Movie Maker (--write-movie) renders slower than real time; follow its fixed delta
	# so recorded trailers play at true speed.
	var elapsed := int(delta * 1_000_000) if OS.has_feature("movie") else now - _last_usec
	_acc += elapsed * SimConst.TICK_HZ
	_last_usec = now
	var due := mini(_acc / 1_000_000, SimConst.TICK_HZ / 10)
	# Ticks lost to a stall are dropped, not banked: the side that's ahead slows down.
	_acc = mini(_acc - due * 1_000_000, 1_000_000)
	if _ended == "" and not _opponent_gone:
		var me := session.local_idx
		var my_board := session.state.boards[me]
		if session.input_open():
			session.set_local_input(_pilot.next_input(my_board) if _pilot else Controls.sample(my_board))
		for p in _cpus.size():
			if _cpus[p]:
				session.set_seat_input(p, _cpus[p].next_input(session.state.boards[p]))
		session.advance(due)
	if _pilot and session.state.winner != -1 and session.state.tick % (SimConst.TICK_HZ * 4) < SimConst.TICKS_PER_FRAME:
		_rematch_sent = true
		Net.request_rematch() # demo loops
	if session.state.winner != -1 and _over_msec == -1:
		_over_msec = Time.get_ticks_msec()
	if session.state.winner != -1 and not _rematch_sent and Input.is_action_just_pressed("swap"):
		_rematch_sent = true
		Net.request_rematch()
	for p in _views.size():
		_views[p].board = session.state.boards[p]
	_sfx.listen(session.state)
	if not _pilot:
		_views[session.local_idx].cursor_cell = Controls.cursor_cell()
		_views[session.local_idx].cursor_held = Controls.holding()
	queue_redraw()


## Keys and buttons swap and leave at the end of a match (see _process). Fingers and mice tap: a
## mouse press arrives as a touch too.
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch and event.pressed):
		return
	if _ended != "" or _opponent_gone:
		_leave()
	elif (_over_msec != -1 and not _pilot and not _rematch_sent
			and Time.get_ticks_msec() - _over_msec >= RETRY_TAP_DELAY_MS):
		_rematch_sent = true
		Net.request_rematch()


func _draw() -> void:
	var font := ThemeDB.fallback_font
	var view := get_viewport_rect().size
	var s := session.state
	var hud := "%d Hz %s" % [SimConst.TICK_HZ, _rules_name()]
	if not _offline:
		hud += "   rtt %d ms   rollbacks %d   resim %d   stalls %d" % [Net.rtt_ms, session.stats.rollbacks,
				session.stats.resim, session.stats.stalls]
	var dp := Controls.dp_scale()
	var hud_size := maxi(16, int(11 * dp))
	if Config.get_value("video", "show_stats"):
		draw_string(font, Vector2(20, 14 + hud_size), hud, HORIZONTAL_ALIGNMENT_LEFT, -1, hud_size, Color(1, 1, 1, 0.5))
	_draw_hint(font)

	var big := ""
	var small := ""
	if s.tick < s.rules.countdown:
		big = str(ceili(float(s.rules.countdown - s.tick) / SimConst.TICK_HZ))
	elif s.tick < s.rules.countdown + SimConst.TICK_HZ / 2:
		big = "GO!"
	if s.winner != -1:
		if _solo():
			big = "GAME OVER"
			small = "score %d" % s.boards[0].score
		else:
			big = "DRAW" if s.is_draw() else ("YOU WIN" if s.won(session.local_idx) else "YOU LOSE")
			if _pilot and not s.is_draw():
				big = "%s WINS" % _label(s.winner).get_slice(" (", 0).to_upper()
		small += ("   waiting for opponent…" if _rematch_sent and not _offline
				else _retry_text())
		if _pilot:
			small = "   demo" if Controls.tap_word() != "" else "   demo — %s for title" % Controls.leave_name()
	if _opponent_gone and _ended == "":
		big = ""
		small = "%s — %s for title" % [Net.gone_why if Net.gone_why != "" else "Opponent left",
				Controls.tap_word() if Controls.tap_word() != "" else Controls.leave_name()]
	if _ended != "":
		big = ""
		small = _ended
	if _notice != "" and Time.get_ticks_msec() - _notice_msec < NOTICE_MS:
		var notice_size := maxi(20, int(13 * dp))
		var at := Vector2(0, 14 + hud_size + notice_size * 2)
		draw_string_outline(font, at, _notice, HORIZONTAL_ALIGNMENT_CENTER, view.x, notice_size, notice_size / 3, Color.BLACK)
		draw_string(font, at, _notice, HORIZONTAL_ALIGNMENT_CENTER, view.x, notice_size, Color(1.0, 0.85, 0.4))
	var big_size := maxi(72, int(40 * dp))
	var small_size := maxi(24, int(16 * dp))
	if big != "":
		draw_string_outline(font, Vector2(0, view.y / 2), big, HORIZONTAL_ALIGNMENT_CENTER, view.x, big_size, big_size / 6, Color.BLACK)
		draw_string(font, Vector2(0, view.y / 2), big, HORIZONTAL_ALIGNMENT_CENTER, view.x, big_size)
	if small != "":
		var at := Vector2(0, view.y / 2 + small_size * 2)
		draw_string_outline(font, at, small, HORIZONTAL_ALIGNMENT_CENTER, view.x, small_size, small_size / 3, Color.BLACK)
		draw_string(font, at, small, HORIZONTAL_ALIGNMENT_CENTER, view.x, small_size)


## Only during the countdown, when there's time to read it and nothing yet to cover.
func _draw_hint(font: Font) -> void:
	if not _hint_showing():
		return
	var rect := _hint_rect()
	var text := _hint_text()
	var hint_size := _hint_size()
	var at := rect.position + Vector2(0, font.get_ascent(hint_size))
	draw_multiline_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, hint_size, -1, hint_size / 3, Color.BLACK)
	draw_multiline_string(font, at, text, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, hint_size)


func _hint_showing() -> bool:
	return session.state.tick < session.state.rules.countdown and not _pilot


## One thing per line: the hint goes in narrow spaces.
func _hint_text() -> String:
	return Controls.hint().replace(" · ", "\n")


func _hint_size() -> int:
	return maxi(HINT_MIN, int(HINT_DP * Controls.dp_scale()))


## Where the hint goes: below the countdown between the boards, or beside a board playing alone.
## A narrow screen has no such space, but the top of your own well is empty until the game starts.
func _hint_rect() -> Rect2:
	var view := get_viewport_rect().size
	var me: Node = _views[session.local_idx]
	if _narrow(view) or session.seats() > 2:
		var top_left: Vector2 = me.cell_to_screen(Vector2.ZERO)
		return Rect2(top_left, me.cell_to_screen(Vector2(SimConst.W, HINT_ROWS)) - top_left)
	var left: Node = _views[0]
	var pad: float = (left.cell_to_screen(Vector2.RIGHT) - left.cell_to_screen(Vector2.ZERO)).x * HINT_PAD_CELLS
	var start: float = EDGE_UNITS if _solo() else left.cell_to_screen(Vector2(SimConst.W, SimConst.H)).x + pad
	var end: float = (left.cell_to_screen(Vector2(0, SimConst.H)).x if _solo()
			else _views[1].cell_to_screen(Vector2(0, SimConst.H)).x) - pad
	var y := view.y / 2.0 + EDGE_UNITS
	return Rect2(start, y, end - start, view.y - y - EDGE_UNITS)


func _retry_text() -> String:
	var again := "retry" if _offline else "rematch"
	if Controls.tap_word() != "":
		return "   %s for %s" % [Controls.tap_word(), again]
	return "   swap for %s · %s for title" % [again, Controls.leave_name()]


func _on_desynced(tick: int) -> void:
	_ended = "DESYNC at tick %d — this is a bug, please report" % tick
	push_error(_ended)


func _on_opponent_left() -> void:
	_opponent_gone = true


func _on_notice(text: String) -> void:
	_notice = text
	_notice_msec = Time.get_ticks_msec()


## Every real match is kept: a bug report is a file, and it replays exactly. Up to the last
## checkpoint both sides agreed, so nothing here can record inputs that later changed.
func _save_replay() -> void:
	if _pilot or not Config.get_value("replay", "save"):
		return
	var replay := Replay.from_session(session)
	if replay == null:
		return
	DirAccess.make_dir_recursive_absolute(REPLAY_DIR)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/%s-%d-p%d.fbgr" % [REPLAY_DIR, stamp, session.game_seed, session.local_idx]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("Can't save replay to %s" % path)
		return
	f.store_buffer(replay.encode())
	f.close()
	var names := DirAccess.get_files_at(REPLAY_DIR)
	names.sort() # timestamps sort oldest first
	for i in names.size() - int(Config.get_value("replay", "keep")):
		DirAccess.remove_absolute("%s/%s" % [REPLAY_DIR, names[i]])


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if session and not _offline:
			print("match end tick=%d stats=%s rtt=%d" % [session.state.tick, session.stats, Net.rtt_ms])
