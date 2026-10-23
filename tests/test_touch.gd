extends SceneTree
## Touch controls through the real Controls node and sim: drag-to-swap, tap to
## move the cursor, hold the rising row to raise.
##   godot --headless --path . -s tests/test_touch.gd

const W := SimConst.W
const ROWS := SimConst.ROWS
const EXPECTED_CHECKS := 4

var _failed := 0
var _ran := 0
var ctrl: Node


func _init() -> void:
	ctrl = load("res://autoload/controls.gd").new()
	ctrl._ready() # registers the bindings; not in the tree, so call it ourselves
	# 100 px per cell; screen (x, y) -> (column, visible row from top).
	ctrl.board_mapper = func(p: Vector2) -> Vector2i: return Vector2i(floori(p.x / 100.0), floori(p.y / 100.0))
	_test_drag_moves_block()
	_test_drag_back_and_forth()
	_test_tap_moves_cursor()
	_test_hold_rising_row_raises()
	ctrl.free()
	_failed += EXPECTED_CHECKS - _ran
	print("PASS" if _failed == 0 else "FAIL (%d)" % _failed)
	quit(0 if _failed == 0 else 1)


func _check(ok: bool, what: String) -> void:
	_ran += 1
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_failed += 1


func _state() -> SimState:
	var s := SimState.create(5, true)
	s.tick = SimConst.COUNTDOWN_TICKS
	s.boards[0].clear_all()
	s.boards[0].stop_t = 1 << 30
	return s


func _touch(pressed: bool, cell: Vector2i) -> void:
	var t := InputEventScreenTouch.new()
	t.pressed = pressed
	t.position = Vector2(cell) * 100.0 + Vector2(50, 50)
	ctrl._unhandled_input(t)


func _drag(cell: Vector2i) -> void:
	var d := InputEventScreenDrag.new()
	d.position = Vector2(cell) * 100.0 + Vector2(50, 50)
	ctrl._unhandled_input(d)


## Runs n frames of sampled touch input through the sim.
func _frames(s: SimState, n: int) -> int:
	var raised := 0
	for f in n:
		var input: int = ctrl.sample(s.boards[0])
		if input & SimConst.RAISE:
			raised += 1
		for t in SimConst.TICKS_PER_FRAME:
			s.step(input, 0)
	return raised


func _row(b: SimBoard, y: int) -> Array:
	var out := []
	for x in W:
		out.append(b.color[(SimConst.BUF + y) * W + x])
	return out


func _test_drag_moves_block() -> void:
	var s := _state()
	var b := s.boards[0]
	var y := SimConst.H - 1
	for x in W:
		b.put(x, 0, [1, 2, 3, 4, 1, 2][x])
	_frames(s, 2)
	_touch(true, Vector2i(1, y))
	_frames(s, 2)
	_drag(Vector2i(2, y))
	_drag(Vector2i(4, y)) # a fast swipe skips a cell; every crossing still swaps
	_frames(s, 20)
	_touch(false, Vector2i(4, y))
	_frames(s, 10)
	_check(_row(b, y) == [1, 3, 4, 1, 2, 2], "dragging a block right carries it along: %s" % [_row(b, y)])


func _test_drag_back_and_forth() -> void:
	var s := _state()
	var b := s.boards[0]
	var y := SimConst.H - 1
	for x in W:
		b.put(x, 0, [1, 2, 3, 4, 1, 2][x])
	_frames(s, 2)
	_touch(true, Vector2i(3, y))
	_drag(Vector2i(5, y))
	_drag(Vector2i(0, y)) # reverse before the queue drains
	_frames(s, 40)
	_touch(false, Vector2i(0, y))
	_frames(s, 10)
	_check(_row(b, y) == [4, 1, 2, 3, 1, 2], "reversing mid-drag ends with the block under the finger: %s" % [_row(b, y)])


func _test_tap_moves_cursor() -> void:
	var s := _state()
	var b := s.boards[0]
	_touch(true, Vector2i(3, 4))
	_frames(s, 2)
	_touch(false, Vector2i(3, 4))
	_frames(s, 2)
	_check(b.cursor_x == 3 and b.cursor_y == SimConst.BUF + 4, "tap puts the cursor there (%d, %d)" % [b.cursor_x, b.cursor_y - SimConst.BUF])


func _test_hold_rising_row_raises() -> void:
	var s := _state()
	_touch(true, Vector2i(2, SimConst.H))
	var raised := _frames(s, 10)
	_touch(false, Vector2i(2, SimConst.H))
	var after := _frames(s, 5)
	_check(raised == 10 and after == 0, "holding the rising row raises, releasing stops")
