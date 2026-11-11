extends SceneTree
## Touch gestures through the real Controls node and sim. Positions are in cell
## units (block x spans [x, x+1)); the mapper is 100 px per cell. A fake clock
## separates deliberate holds (carry) from strokes that start moving at once (flick).
##   godot --headless --path . -s tests/test_touch.gd

const W := SimConst.W
const Y := SimConst.H - 1 # bottom visible row
const ROW := [1, 2, 3, 4, 1, 2]
const EXPECTED_CHECKS := 28

var _failed := 0
var _ran := 0
var ctrl: Node
var now := 0


func _initialize() -> void:
	# Autoloads aren't ready until the first frame.
	await process_frame
	ctrl = root.get_node("Controls")
	ctrl.board_mapper = func(p: Vector2) -> Vector2: return p / 100.0
	ctrl.clock = func() -> int: return now
	_test_carry_moves_block()
	_test_carry_reverse()
	_test_carry_jitter_at_boundary()
	_test_flick_across_four_is_middle_swap()
	_test_flick_pencil_stroke_row()
	_test_tap_wobble_is_one_swap()
	_test_tap_moves_cursor()
	_test_tap_swaps_the_pair_either_side()
	_test_tap_near_the_walls()
	_test_tap_leaves_the_cursor_on_the_pair()
	_test_pressing_shows_the_pair()
	_test_tap_on_garbage_doesnt_wait()
	_test_quick_taps_all_count()
	_test_delayed_carry_loses_nothing()
	_test_delayed_quick_taps()
	_test_no_delay_no_wait()
	_test_hold_rising_row_raises()
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


func _test_tap_wobble_is_one_swap() -> void:
	var s := _state()
	_stroke([Vector2(2.6, Y + 0.5), Vector2(2.7, Y + 0.6), Vector2(2.4, Y + 0.45), Vector2(2.6, Y + 0.5)], 30)
	_frames(s, 10)
	_check(_row(s.boards[0], Y) == [1, 2, 4, 3, 1, 2], "a wobbly tap is still one tap, and swaps once: %s" % [_row(s.boards[0], Y)])


func _test_tap_moves_cursor() -> void:
	var s := _state()
	var b := s.boards[0]
	_stroke([Vector2(3.5, 4.5)], 0)
	_frames(s, 3)
	_check(b.cursor_x == 3 and b.cursor_y == SimConst.BUF + 4, "a tap on empty space puts the cursor there, centred (%d, %d)" % [b.cursor_x, b.cursor_y - SimConst.BUF])


func _test_tap_swaps_the_pair_either_side() -> void:
	for at: Array in [[2.1, [1, 3, 2, 4, 1, 2]], [1.9, [1, 3, 2, 4, 1, 2]], [2.9, [1, 2, 4, 3, 1, 2]], [3.1, [1, 2, 4, 3, 1, 2]]]:
		var s := _state()
		_stroke([Vector2(at[0], Y + 0.5)], 0)
		_frames(s, 10)
		_check(_row(s.boards[0], Y) == at[1], "a tap at %.1f swaps the two either side of the nearest boundary: %s" % [at[0], _row(s.boards[0], Y)])


func _test_tap_near_the_walls() -> void:
	var s := _state()
	_stroke([Vector2(0.1, Y + 0.5)], 0)
	_frames(s, 10)
	_check(_row(s.boards[0], Y) == [2, 1, 3, 4, 1, 2], "against the left wall, it's the first pair: %s" % [_row(s.boards[0], Y)])
	s = _state()
	_stroke([Vector2(5.9, Y + 0.5)], 0)
	_frames(s, 10)
	_check(_row(s.boards[0], Y) == [1, 2, 3, 4, 2, 1], "against the right wall, the last: %s" % [_row(s.boards[0], Y)])


func _test_tap_leaves_the_cursor_on_the_pair() -> void:
	var s := _state()
	_stroke([Vector2(2.9, Y + 0.5)], 0)
	_frames(s, 10)
	_check(s.boards[0].cursor_x == 2, "the cursor stays on the pair it swapped: %d" % s.boards[0].cursor_x)


func _test_pressing_shows_the_pair() -> void:
	var s := _state()
	_touch(true, Vector2(2.9, Y + 0.5))
	_frames(s, 2)
	_check(s.boards[0].cursor_x == 2, "a press shows the pair it'll swap before it's let go: %d" % s.boards[0].cursor_x)
	_touch(false, Vector2(2.9, Y + 0.5))
	_frames(s, 2)


func _test_tap_on_garbage_doesnt_wait() -> void:
	var s := _state()
	var b := s.boards[0]
	var slab := (SimBoard.ROWS - 1) * W + 3
	b.color[slab] = SimConst.GARBAGE
	b.gid[slab] = 9
	var before := _row(b, Y)
	_stroke([Vector2(2.9, Y + 0.5)], 0)
	_frames(s, 4)
	_check(ctrl._steps.is_empty() and _row(b, Y) == before, "a tap on garbage does nothing, and has nothing left to go off later")


## As online: the board plays each input this many frames after it was sampled, and the
## gesture only ever sees the board as it is by then.
func _delayed_frames(s: SimState, n: int, delay: int, pending: Array[int]) -> int:
	var swaps := 0
	for f in n:
		now += 16
		var input: int = ctrl.sample(s.boards[0])
		if input & SimConst.SWAP:
			swaps += 1
		pending.append(input)
		var run: int = pending.pop_front() if pending.size() > delay else 0
		for t in SimConst.TICKS_PER_FRAME:
			s.step(run, 0)
	return swaps


func _test_delayed_carry_loses_nothing() -> void:
	ctrl.input_is_delayed = true
	for delay: int in [1, 2, 4, 8]:
		var s := _state()
		var b := s.boards[0]
		var before: int = b.swaps
		var pending: Array[int] = []
		_touch(true, Vector2(0.5, Y + 0.5))
		now += 300
		var sent := 0
		for i in 12: # a quick drag, three cells in a fifth of a second
			_drag(Vector2(0.5 + 3.0 * (i + 1) / 12.0, Y + 0.5))
			sent += _delayed_frames(s, 1, delay, pending)
		_touch(false, Vector2(3.5, Y + 0.5))
		sent += _delayed_frames(s, 40, delay, pending)
		_check(sent == 3 and b.swaps - before == 3 and _row(b, Y).find(1) == 3,
				"%d frames late, a quick carry's swaps all land: sent %d, played %d, %s" % [delay, sent, b.swaps - before, _row(b, Y)])
	ctrl.input_is_delayed = false


func _test_delayed_quick_taps() -> void:
	ctrl.input_is_delayed = true
	var s := _state()
	var b := s.boards[0]
	var before: int = b.swaps
	var pending: Array[int] = []
	_stroke([Vector2(1.9, Y + 0.5)], 0) # 1 and 2
	_delayed_frames(s, 2, 2, pending)
	_stroke([Vector2(1.9, Y + 0.5)], 0) # and back
	_delayed_frames(s, 30, 2, pending)
	_check(b.swaps - before == 2 and _row(b, Y) == ROW, "tapping one pair twice, online, swaps it there and back: %s" % [_row(b, Y)])
	s = _state()
	pending = []
	_stroke([Vector2(0.9, Y + 0.5)], 0)
	_delayed_frames(s, 1, 2, pending)
	_stroke([Vector2(2.9, Y + 0.5)], 0)
	_stroke([Vector2(4.9, Y + 0.5)], 0)
	var waited := _delayed_frames(s, 4, 2, pending) # release, swap, release, swap: no waiting in that
	_check(waited == 2, "while taps on separate pairs don't wait for each other: %d" % waited)
	_delayed_frames(s, 10, 2, pending)
	_check(_row(s.boards[0], Y) == [2, 1, 4, 3, 2, 1], "and they all land: %s" % [_row(s.boards[0], Y)])
	ctrl.input_is_delayed = false


func _test_no_delay_no_wait() -> void:
	var s := _state()
	var sent := []
	_touch(true, Vector2(0.5, Y + 0.5))
	now += 300
	_drag(Vector2(2.6, Y + 0.5))
	var at := -1
	var second := -1
	for i in 20:
		now += 16
		var input: int = ctrl.sample(s.boards[0])
		if input & SimConst.SWAP:
			if at == -1:
				at = i
			elif second == -1:
				second = i
		for t in SimConst.TICKS_PER_FRAME:
			s.step(input, 0)
	_touch(false, Vector2(2.6, Y + 0.5))
	_frames(s, 10)
	_check(second - at == 4, "offline, the board's word is enough: a carry goes as fast as swaps finish, %d frames" % (second - at))
	_check(_row(s.boards[0], Y).find(1) == 2, "and lands: %s" % [_row(s.boards[0], Y)])


func _test_quick_taps_all_count() -> void:
	var s := _state()
	_stroke([Vector2(0.9, Y + 0.5)], 0) # 0 and 1
	_frames(s, 1)
	_stroke([Vector2(3.1, Y + 0.5)], 0) # 2 and 3
	_frames(s, 1)
	_stroke([Vector2(5.1, Y + 0.5)], 0) # 4 and 5
	_frames(s, 10)
	_check(_row(s.boards[0], Y) == [2, 1, 4, 3, 2, 1], "quick taps around the board all swap: %s" % [_row(s.boards[0], Y)])
	s = _state(2)
	var upper := _row(s.boards[0], Y - 1)
	_stroke([Vector2(0.9, Y + 0.5)], 0)
	_stroke([Vector2(0.9, Y - 0.5)], 0) # two rows, between one sample and the next
	_frames(s, 10)
	var want := upper.duplicate()
	var first: int = want[0]
	want[0] = want[1]
	want[1] = first
	_check(_row(s.boards[0], Y) == [2, 1, 3, 4, 1, 2] and _row(s.boards[0], Y - 1) == want, "each on its own row, even between samples: %s %s" % [_row(s.boards[0], Y), _row(s.boards[0], Y - 1)])


func _test_hold_rising_row_raises() -> void:
	var s := _state()
	_touch(true, Vector2(2.5, SimConst.H + 0.5))
	var raised := _frames(s, 10)
	_touch(false, Vector2(2.5, SimConst.H + 0.5))
	var after := _frames(s, 5)
	_check(raised == 10 and after == 0, "holding the rising row raises, releasing stops")
