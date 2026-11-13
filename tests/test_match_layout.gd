extends SceneTree
## The match in the real scene at desktop and phone shapes: every board on screen, your cells
## big enough for a finger, touches landing on the cell drawn there, and a drag moving the block.
##   godot --headless --path . -s tests/test_match_layout.gd

# Tests see a screen scale of 1, so the smaller sizes stand in for phones measured in dp.
const SIZES: Array[Vector2i] = [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(800, 600),
		Vector2i(915, 412), Vector2i(800, 360), Vector2i(412, 915), Vector2i(360, 800),
		Vector2i(320, 568), Vector2i(768, 1024), Vector2i(600, 600)]
const FINGER_DP := 38.0 # the smallest cell once your board goes big, on the smallest phone here
const FINGER_DP_MANY := 30.0 # the same with five other boards beside yours
const MANY := [[0, 0, 1, 1], [0, 0, 0, 1, 1, 1], [0, 1, 2]]
const W := SimConst.W
const H := SimConst.H
const Y := H - 1 # bottom visible row
const ROW := [1, 2, 3, 4, 1, 2]
const EXPECTED_CHECKS := 711

var _failed := 0
var _ran := 0
var _net: Node
var _config: Node
var _controls: Node
var _now := 0


func _initialize() -> void:
	await process_frame # autoloads aren't ready until the first frame
	_net = root.get_node("Net")
	_config = root.get_node("Config")
	_controls = root.get_node("Controls")
	_controls.clock = func() -> int: return _now
	_config._cfg.set_value("replay", "save", false) # in memory: set_value would write the player's file
	for renderer: String in ["3d", "2d"]:
		_config._cfg.set_value("video", "renderer", renderer)
		for size: Vector2i in SIZES:
			for setup: Array in [["Overmind", 0], ["Overmind", 1], ["", 0]]:
				await _test_layout(renderer, size, setup[0], setup[1])
			for teams: Array in MANY:
				await _test_many(renderer, size, PackedInt32Array(teams))
		await _test_desktop_unchanged(renderer)
		await _test_turning_the_phone(renderer)
	_failed += EXPECTED_CHECKS - _ran # a script error stops a test without failing a check
	print("PASS" if _failed == 0 else "FAIL (%d)" % _failed)
	quit(0 if _failed == 0 else 1)


func _start(size: Vector2i, cpu: String, idx: int) -> Node:
	root.size = size
	_net.remote_id = 0
	_net.local_idx = idx
	_net.match_seed = 5
	_net.cpu_name = cpu
	_net.cpu_level = "normal"
	_net.demo = false
	_net.match_teams = PackedInt32Array()
	var scene: Node = load("res://scenes/match.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame
	return scene


## Where a point in a board's cell units is drawn, on its z = 0 plane.
func _screen(view: Node, cell: Vector2) -> Vector2:
	var y: float = cell.y - BoardView.lift(view.board)
	if view is BoardRenderer3D:
		var at := Vector3(cell.x - W / 2.0, H / 2.0 - y, 0)
		return view.get_viewport().get_camera_3d().unproject_position(view.global_transform * at)
	return view.get_global_transform_with_canvas() * (Vector2(cell.x, y) * BoardRenderer2D.CELL)


func _board_rect(view: Node) -> Rect2:
	var top_left := _screen(view, Vector2.ZERO)
	return Rect2(top_left, _screen(view, Vector2(W, H + 1)) - top_left)


func _test_layout(renderer: String, size: Vector2i, cpu: String, idx: int) -> void:
	var scene := await _start(size, cpu, idx)
	var screen := root.get_visible_rect()
	var what := "%s %s %s seat %d" % [renderer, size, cpu if cpu != "" else "solo", idx]
	var mine: Node = scene._views[idx]
	var rect := _board_rect(mine)
	_check(screen.encloses(rect), "your board %s on screen %s: %s" % [rect, screen.size, what])
	if cpu != "":
		var theirs := _board_rect(scene._views[1 - idx])
		_check(screen.encloses(theirs), "their board %s on screen %s: %s" % [theirs, screen.size, what])
		_check(not rect.intersects(theirs), "boards apart: " + what)
	if float(size.x) / size.y < scene.SIDE_BY_SIDE_ASPECT:
		var dp: float = (rect.size.x / W) / _controls.dp_scale()
		_check(dp >= FINGER_DP, "cells are %.1f dp: %s" % [dp, what])
	_check(_every_cell_maps(mine), "touches land on the cell drawn there: " + what)
	_check(_drag_moves_block(mine), "a drag moves the block under it: " + what)
	scene.free()


## More than two boards: all of them on screen and apart, and yours still big enough to play.
func _test_many(renderer: String, size: Vector2i, teams: PackedInt32Array) -> void:
	root.size = size
	_net.remote_id = 0
	_net.local_idx = 0
	_net.match_seed = 5
	_net.cpu_name = "Overmind"
	_net.cpu_level = "normal"
	_net.demo = false
	_net.match_teams = teams
	var scene: Node = load("res://scenes/match.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame
	var screen := root.get_visible_rect()
	var what := "%s %s teams %s" % [renderer, size, teams]
	var rects: Array[Rect2] = []
	for p in teams.size():
		var r := _board_rect(scene._views[p])
		rects.append(r)
		_check(screen.encloses(r), "board %d %s on screen %s: %s" % [p, r, screen.size, what])
	var apart := true
	for a in rects.size():
		for b in range(a + 1, rects.size()):
			apart = apart and not rects[a].intersects(rects[b])
	_check(apart, "boards apart: %s %s" % [what, rects])
	var mine: Node = scene._views[0]
	if float(size.x) / size.y < scene.SIDE_BY_SIDE_ASPECT:
		var dp: float = (rects[0].size.x / W) / _controls.dp_scale()
		_check(dp >= FINGER_DP_MANY, "cells are %.1f dp: %s" % [dp, what])
	_check(_every_cell_maps(mine), "touches land on the cell drawn there: " + what)
	_net.match_teams = PackedInt32Array()
	scene.free()


func _every_cell_maps(view: Node) -> bool:
	for y in H + 1:
		for x in W:
			var hit: Vector2 = view.screen_to_cell(_screen(view, Vector2(x + 0.5, y + 0.5)))
			if Vector2i(hit.floor()) != Vector2i(x, y):
				print("    cell %d,%d mapped to %s" % [x, y, hit])
				return false
	for outside: Vector2 in [Vector2(-0.2, 3), Vector2(W + 0.2, 3), Vector2(3, -0.2), Vector2(3, H + 1.2)]:
		if view.screen_to_cell(_screen(view, outside)) != Vector2(-1, -1):
			print("    %s, off the board, mapped to a cell" % outside)
			return false
	return true


## The real Controls and the real screen mapper, carrying a block from column 1 to column 4.
func _drag_moves_block(view: Node) -> bool:
	var s := SimState.create(5, true)
	s.tick = SimConst.COUNTDOWN_TICKS
	var b := s.boards[0]
	b.clear_all()
	b.stop_t = 1 << 30
	for x in W:
		b.put(x, 0, ROW[x])
	view.board = b
	_frames(s, 2)
	_controls.reset_touch()
	_touch(true, _screen(view, Vector2(1.5, Y + 0.5)))
	_now += 200 # rests on it: carry
	_drag(_screen(view, Vector2(2.6, Y + 0.5)))
	_drag(_screen(view, Vector2(4.5, Y + 0.5)))
	_frames(s, 30)
	_touch(false, _screen(view, Vector2(4.5, Y + 0.5)))
	_frames(s, 10)
	_controls.reset_touch()
	var row := []
	for x in W:
		row.append(b.color[(SimConst.BUF + Y) * W + x])
	if row != [1, 3, 4, 1, 2, 2]:
		print("    row is %s" % [row])
		return false
	return true


func _frames(s: SimState, n: int) -> void:
	for f in n:
		_now += 16
		var input: int = _controls.sample(s.boards[0])
		for t in SimConst.TICKS_PER_FRAME:
			s.step(input, 0)


func _touch(pressed: bool, p: Vector2) -> void:
	var t := InputEventScreenTouch.new()
	t.pressed = pressed
	t.position = p
	_controls._unhandled_input(t)


func _drag(p: Vector2) -> void:
	var d := InputEventScreenDrag.new()
	d.position = p
	_controls._unhandled_input(d)


func _check_side_by_side(scene: Node, what: String) -> void:
	for p in 2:
		var view: Node = scene._views[p]
		if view is BoardRenderer3D:
			_check(view.position == Vector3(-6.5 + 13.0 * p, 0, 0) and view.scale == Vector3.ONE, "board %d in its place: %s" % [p, what])
		else:
			_check(view.position == Vector2(280.0 + p * 480.0, 120) and view.scale == Vector2.ONE, "board %d in its place: %s" % [p, what])
	if scene._cam:
		_check(scene._cam.position == Vector3(0, 0.3, 20.5) and is_equal_approx(scene._cam.fov, 42.0), "camera in its place: " + what)


func _test_desktop_unchanged(renderer: String) -> void:
	var scene := await _start(Vector2i(1280, 720), "Overmind", 0)
	_check_side_by_side(scene, "%s 1280x720" % renderer)
	scene.free()


func _test_turning_the_phone(renderer: String) -> void:
	var scene := await _start(Vector2i(412, 915), "Overmind", 1)
	var tall: Rect2 = _board_rect(scene._views[1])
	root.size = Vector2i(915, 412)
	await process_frame
	await process_frame
	var wide: Rect2 = _board_rect(scene._views[1])
	_check(root.get_visible_rect().encloses(wide), "%s board on screen after turning sideways: %s" % [renderer, wide])
	_check(_every_cell_maps(scene._views[1]), "%s touches still map after turning sideways" % renderer)
	root.size = Vector2i(412, 915)
	await process_frame
	await process_frame
	var back: Rect2 = _board_rect(scene._views[1])
	_check(back.position.is_equal_approx(tall.position) and back.size.is_equal_approx(tall.size), "%s turning back restores the layout: %s %s" % [renderer, tall, back])
	scene.free()


func _check(ok: bool, what: String) -> void:
	_ran += 1
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_failed += 1
