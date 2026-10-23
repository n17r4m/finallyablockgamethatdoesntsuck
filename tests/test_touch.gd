extends SceneTree
## Touch gestures through the real Controls node and sim. Positions are in cell
## units (block x spans [x, x+1)); the mapper is 100 px per cell. A fake clock
## separates deliberate holds (carry) from strokes that start moving at once (flick).
##   godot --headless --path . -s tests/test_touch.gd

const W := SimConst.W
const Y := SimConst.H - 1 # bottom visible row
const ROW := [1, 2, 3, 4, 1, 2]
const EXPECTED_CHECKS := 8

var _failed := 0
var _ran := 0
var ctrl: Node
var now := 0


func _init() -> void:
	ctrl = load("res://autoload/controls.gd").new()
	ctrl._ready() # registers the bindings; not in the tree, so call it ourselves
	ctrl.board_mapper = func(p: Vector2) -> Vector2: return p / 100.0
	ctrl.clock = func() -> int: return now
	_test_carry_moves_block()
	_test_carry_reverse()
	_test_carry_jitter_at_boundary()
	_test_flick_across_four_is_middle_swap()
	_test_flick_pencil_stroke_row()
	_test_tap_wobble_is_not_a_swap()
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


func _state(rows := 1) -> SimState:
	var s := SimState.create(5, true)
	s.tick = SimConst.COUNTDOWN_TICKS
	var b := s.boards[0]
	b.clear_all()
	b.stop_t = 1 << 30
	for r in rows:
		for x in W:
			b.put(x, r, ROW[(x + r * 2) % W])
	_frames(s, 2)
	return s


func _touch(pressed: bool, p: Vector2) -> void:
	var t := InputEventScreenTouch.new()
	t.pressed = pressed
	t.position = p * 100.0
	ctrl._unhandled_input(t)


func _drag(p: Vector2) -> void:
	var d := InputEventScreenDrag.new()
	d.position = p * 100.0
	ctrl._unhandled_input(d)


## A stroke through points, `ms` apart, optionally releasing at the end.
func _stroke(points: Array, ms: int, release := true) -> void:
	_touch(true, points[0])
	for i in range(1, points.size()):
		now += ms
		_drag(points[i])
	if release:
		_touch(false, points[-1])


func _frames(s: SimState, n: int) -> int:
	var raised := 0
	for f in n:
		now += 16
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


func _test_carry_moves_block() -> void:
	var s := _state()
	_touch(true, Vector2(1.5, Y + 0.5))
	now += 200 # rests on it: carry
	_drag(Vector2(2.6, Y + 0.5))
	_drag(Vector2(4.5, Y + 0.5))
	_frames(s, 30)
	_touch(false, Vector2(4.5, Y + 0.5))
	_frames(s, 10)
	_check(_row(s.boards[0], Y) == [1, 3, 4, 1, 2, 2], "carry: block follows the finger 1 -> 4: %s" % [_row(s.boards[0], Y)])


func _test_carry_reverse() -> void:
	var s := _state()
	_touch(true, Vector2(3.5, Y + 0.5))
	now += 200
	_drag(Vector2(5.5, Y + 0.5))
	_drag(Vector2(0.5, Y + 0.5))
	_frames(s, 60)
	_touch(false, Vector2(0.5, Y + 0.5))
	_frames(s, 10)
	_check(_row(s.boards[0], Y) == [4, 1, 2, 3, 1, 2], "carry: reversing mid-drag ends under the finger: %s" % [_row(s.boards[0], Y)])


func _test_carry_jitter_at_boundary() -> void:
	var s := _state()
	_touch(true, Vector2(1.5, Y + 0.5))
	now += 200
	for i in 10: # dithering just past the 1|2 boundary, inside the margin
		_drag(Vector2(2.15 if i % 2 == 0 else 1.9, Y + 0.5))
	_frames(s, 20)
	_touch(false, Vector2(2.1, Y + 0.5))
	_frames(s, 10)
	_check(_row(s.boards[0], Y) == ROW, "carry: jitter at a boundary (and on release) doesn't swap")


func _test_flick_across_four_is_middle_swap() -> void:
	# A quick stroke from A's centre to D's: messy ends trimmed, it's the B-C swap.
	var s := _state()
	_stroke([Vector2(0.5, Y + 0.5), Vector2(1.4, Y + 0.45), Vector2(2.6, Y + 0.55), Vector2(3.5, Y + 0.5)], 15)
	_frames(s, 10)
	_check(_row(s.boards[0], Y) == [1, 3, 2, 4, 1, 2], "flick A->D across four blocks swaps B-C: %s" % [_row(s.boards[0], Y)])


func _test_flick_pencil_stroke_row() -> void:
	# Two rows. The stroke lands on the block *below* B, but the line runs through
	# A-B's row: the swap is A-B, in the upper row.
	var s := _state(2)
	var b := s.boards[0]
	var upper := Y - 1
	var before_upper := _row(b, upper)
	var before_lower := _row(b, Y)
	_stroke([Vector2(1.55, Y + 0.15), Vector2(1.35, upper + 0.75), Vector2(1.0, upper + 0.55),
			Vector2(0.65, upper + 0.5), Vector2(0.4, upper + 0.55)], 15)
	_frames(s, 10)
	var expect := before_upper.duplicate()
	expect[0] = before_upper[1]
	expect[1] = before_upper[0]
	_check(_row(b, upper) == expect and _row(b, Y) == before_lower,
			"pencil stroke from the block below B: A-B swaps in the stroke's row: %s" % [_row(b, upper)])


func _test_tap_wobble_is_not_a_swap() -> void:
	var s := _state()
	_stroke([Vector2(2.5, Y + 0.5), Vector2(2.7, Y + 0.6), Vector2(2.4, Y + 0.45), Vector2(2.6, Y + 0.5)], 30)
	_frames(s, 10)
	_check(_row(s.boards[0], Y) == ROW and s.boards[0].cursor_x == 2, "a wobbly tap moves the cursor and swaps nothing")


func _test_tap_moves_cursor() -> void:
	var s := _state()
	var b := s.boards[0]
	_stroke([Vector2(3.5, 4.5)], 0)
	_frames(s, 3)
	_check(b.cursor_x == 3 and b.cursor_y == SimConst.BUF + 4, "tap puts the cursor there (%d, %d)" % [b.cursor_x, b.cursor_y - SimConst.BUF])


func _test_hold_rising_row_raises() -> void:
	var s := _state()
	_touch(true, Vector2(2.5, SimConst.H + 0.5))
	var raised := _frames(s, 10)
	_touch(false, Vector2(2.5, SimConst.H + 0.5))
	var after := _frames(s, 5)
	_check(raised == 10 and after == 0, "holding the rising row raises, releasing stops")
