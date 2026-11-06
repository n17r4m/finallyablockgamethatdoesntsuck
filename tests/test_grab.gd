extends SceneTree
## The one-block grab cursor through the real Controls node and sim: keys through the real Input,
## touches as the viewport delivers them, blocks judged by where they end up on the board.
##   godot --headless --path . -s tests/test_grab.gd

const W := SimConst.W
const Y := SimConst.H - 1 # bottom visible row
const ROW := [1, 2, 3, 4, 1, 2]
const NO_RAISE := 1 << 30

const EXPECTED_CHECKS := 94
var _failed := 0
var _ran := 0
var ctrl: Node
var now := 0


func _initialize() -> void:
	await process_frame # autoloads aren't ready until the first frame
	ctrl = root.get_node("Controls")
	ctrl.board_mapper = func(p: Vector2) -> Vector2: return p / 100.0
	ctrl.clock = func() -> int: return now
	ctrl.grab_mode = true
	_test_cursor_starts_on_the_sims()
	_test_cursor_reaches_every_column()
	_test_arrows_move_without_swapping()
	_test_hold_carries_and_release_stops()
	_test_tap_of_swap_moves_nothing()
	_test_vertical_is_ignored_while_holding()
	_test_nothing_grabbed_from_empty_space()
	_test_garbage_cant_be_grabbed_or_crossed()
	_test_block_dropping_over_a_gap_leaves_the_hand()
	_test_nothing_moves_in_the_countdown()
	_test_move_during_a_finishing_carry_isnt_lost()
	_test_stack_rising_carries_the_cursor()
	_test_small_rollback_of_rise_leaves_the_cursor()
	_test_touch_press_carry_release()
	_test_touch_on_empty_follows_the_finger()
	_test_touch_off_the_board_stays_put()
	_test_touch_rising_row_raises()
	_test_pointer_carries_the_cursor()
	_test_pointer_ignores_what_isnt_floating()
	_test_keys_take_over_from_the_pointer()
	_test_pointer_stays_with_a_rising_stack()
	_test_pointer_carries_a_key_grab()
	_test_pointer_waits_for_a_press()
	_test_every_input_is_legal()
	_test_input_delay_paces_the_carry()
	_test_rust_rules_agree()
	ctrl.grab_mode = false
	_test_swap_mode_unaffected()
	_failed += absi(EXPECTED_CHECKS - _ran) # a script error stops a test without failing a check
	print("PASS" if _failed == 0 else "FAIL (%d of %d checks ran, %d failed or missing)" % [_ran, EXPECTED_CHECKS, _failed])
	quit(0 if _failed == 0 else 1)


func _check(ok: bool, what: String) -> void:
	_ran += 1
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_failed += 1


## One board, in play, not rising, with a full bottom row. The second row is only as wide as asked.
func _state(rows := 1) -> SimState:
	ctrl.reset_touch()
	var s := SimState.create(5, true)
	s.tick = SimConst.COUNTDOWN_TICKS
	var b := s.boards[0]
	b.clear_all()
	b.stop_t = NO_RAISE
	b.age = 1
	for r in rows:
		for x in W:
			b.put(x, r, ROW[(x + r * 2) % W])
	_frames(s, 2)
	return s


## As the match does it, keeping every mask so tests can look at what was sent.
func _frames(s: SimState, n: int, sent: Array = []) -> void:
	for f in n:
		now += 16
		var input: int = ctrl.sample(s.boards[0])
		sent.append(input)
		for t in SimConst.TICKS_PER_FRAME:
			s.step(input, 0)


func _settle(s: SimState) -> void:
	_frames(s, 12)


func _key(code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _tap(s: SimState, code: Key) -> void:
	_key(code, true)
	_frames(s, 1)
	_key(code, false)
	_frames(s, 1)


func _touch(pressed: bool, p: Vector2) -> void:
	var t := InputEventScreenTouch.new()
	t.pressed = pressed
	t.position = p * 100.0
	ctrl._unhandled_input(t)


func _drag(p: Vector2) -> void:
	var d := InputEventScreenDrag.new()
	d.position = p * 100.0
	ctrl._unhandled_input(d)


func _bottom(b: SimBoard) -> Array:
	var out := []
	var y := SimBoard.ROWS - 1
	for x in W:
		out.append(b.color[y * W + x])
	return out


func _put_cursor(s: SimState, at: Vector2i) -> void:
	ctrl._grab = at
	_frames(s, 1)


func _test_cursor_starts_on_the_sims() -> void:
	var s := SimState.create(5, true)
	ctrl.reset_touch()
	_check(ctrl.cursor_cell() == Vector2i(-1, -1), "no cell before the first sample")
	_frames(s, 1)
	var b := s.boards[0]
	_check(ctrl.cursor_cell() == Vector2i(b.cursor_x, b.cursor_y - SimBoard.TOP), "starts where the sim's cursor does: %s" % ctrl.cursor_cell())


func _test_cursor_reaches_every_column() -> void:
	var s := _state()
	_put_cursor(s, Vector2i(4, Y))
	_tap(s, KEY_RIGHT)
	_check(ctrl.cursor_cell().x == W - 1, "one block wide, so it reaches the last column: %d" % ctrl.cursor_cell().x)
	_check(s.boards[0].cursor_x == W - 2, "where the sim's cursor still fits around it")
	_tap(s, KEY_RIGHT)
	_check(ctrl.cursor_cell().x == W - 1, "and stops at the wall")
	_put_cursor(s, Vector2i(0, 0))
	_tap(s, KEY_LEFT)
	_tap(s, KEY_UP)
	_check(ctrl.cursor_cell() == Vector2i.ZERO, "and at the other wall and the top")


func _test_arrows_move_without_swapping() -> void:
	var s := _state()
	var before := _bottom(s.boards[0])
	_put_cursor(s, Vector2i(1, Y))
	_tap(s, KEY_RIGHT)
	_tap(s, KEY_RIGHT)
	_check(ctrl.cursor_cell() == Vector2i(3, Y), "each tap moves one cell: %s" % ctrl.cursor_cell())
	_key(KEY_LEFT, true)
	_frames(s, 8) # under the repeat delay
	_check(ctrl.cursor_cell().x == 2, "holding moves once at first")
	_frames(s, 12)
	_check(ctrl.cursor_cell().x == 0, "then repeats: %d" % ctrl.cursor_cell().x)
	_key(KEY_LEFT, false)
	_settle(s)
	_check(_bottom(s.boards[0]) == before, "and no blocks moved")


func _test_hold_carries_and_release_stops() -> void:
	var s := _state()
	var b := s.boards[0]
	_put_cursor(s, Vector2i(0, Y))
	_key(KEY_SPACE, true)
	_frames(s, 1)
	_check(ctrl.holding(), "holding swap grabs")
	_tap(s, KEY_RIGHT)
	_tap(s, KEY_RIGHT)
	_settle(s)
	_check(_bottom(b) == [2, 3, 1, 4, 1, 2], "the block travelled two cells: %s" % [_bottom(b)])
	_check(ctrl.cursor_cell() == Vector2i(2, Y), "with the cursor on it: %s" % ctrl.cursor_cell())
	_key(KEY_SPACE, false)
	_frames(s, 1)
	_check(not ctrl.holding(), "letting go ends the grab")
	_tap(s, KEY_RIGHT)
	_settle(s)
	_check(_bottom(b) == [2, 3, 1, 4, 1, 2], "after which moving moves only the cursor")
	_check(ctrl.cursor_cell() == Vector2i(3, Y), "which it did")


func _test_tap_of_swap_moves_nothing() -> void:
	var s := _state()
	var before := _bottom(s.boards[0])
	_put_cursor(s, Vector2i(2, Y))
	_tap(s, KEY_SPACE)
	_settle(s)
	_check(_bottom(s.boards[0]) == before, "a grab that goes nowhere moves nothing")
	_check(not ctrl.holding(), "and has ended")


func _test_vertical_is_ignored_while_holding() -> void:
	var s := _state(2)
	_put_cursor(s, Vector2i(0, Y))
	_key(KEY_SPACE, true)
	_frames(s, 1)
	_tap(s, KEY_UP)
	_settle(s)
	_check(ctrl.cursor_cell() == Vector2i(0, Y), "a block in hand stays in its row")
	_check(ctrl.holding(), "and stays in hand")
	_key(KEY_SPACE, false)
	_frames(s, 1)


func _test_nothing_grabbed_from_empty_space() -> void:
	var s := _state()
	var before := _bottom(s.boards[0])
	_put_cursor(s, Vector2i(2, Y - 3))
	_key(KEY_SPACE, true)
	_frames(s, 1)
	_check(not ctrl.holding(), "nothing to take in empty space")
	_tap(s, KEY_RIGHT)
	_check(ctrl.cursor_cell() == Vector2i(3, Y - 3), "so the cursor just moves")
	_key(KEY_SPACE, false)
	_settle(s)
	_check(_bottom(s.boards[0]) == before, "and no blocks did")


func _test_garbage_cant_be_grabbed_or_crossed() -> void:
	var s := _state()
	var b := s.boards[0]
	var slab := (SimBoard.ROWS - 1) * W + 2
	b.gid[slab] = 9
	b.color[slab] = SimConst.GARBAGE
	_put_cursor(s, Vector2i(2, Y))
	_key(KEY_SPACE, true)
	_frames(s, 1)
	_check(not ctrl.holding(), "garbage can't be grabbed")
	_key(KEY_SPACE, false)
	_frames(s, 1)
	_put_cursor(s, Vector2i(1, Y))
	_key(KEY_SPACE, true)
	_frames(s, 1)
	var before := _bottom(b)
	_tap(s, KEY_RIGHT)
	_settle(s)
	_check(_bottom(b) == before, "or swapped through")
	_check(ctrl.cursor_cell() == Vector2i(1, Y), "and the cursor stays with its block")
	_check(ctrl._steps.is_empty(), "with nothing left waiting to happen later")
	_key(KEY_SPACE, false)
	_frames(s, 1)


func _test_block_dropping_over_a_gap_leaves_the_hand() -> void:
	var s := _state()
	var b := s.boards[0]
	b.put(0, 1, 5) # one block on the bottom row's left end
	b.color[(SimBoard.ROWS - 1) * W + 1] = 0 # and a hole next to it to drop into
	_frames(s, 2)
	_put_cursor(s, Vector2i(0, Y - 1))
	_key(KEY_SPACE, true)
	_frames(s, 1)
	_check(ctrl.holding(), "a block on the stack can be grabbed")
	_tap(s, KEY_RIGHT)
	_frames(s, 40)
	_check(not ctrl.holding(), "once it drops it's out of the hand")
	_check(b.color[(SimBoard.ROWS - 2) * W + 1] == 0 and b.color[(SimBoard.ROWS - 1) * W + 1] == 5, "having fallen into the hole")
	_tap(s, KEY_LEFT)
	_settle(s)
	_check(ctrl.cursor_cell().x == 0, "and the cursor moves freely again, though swap is still held")
	_key(KEY_SPACE, false)
	_frames(s, 1)


func _test_nothing_moves_in_the_countdown() -> void:
	ctrl.reset_touch()
	var s := SimState.create(5, true)
	var b := s.boards[0]
	var before := b.color.duplicate()
	_frames(s, 1)
	_put_cursor(s, Vector2i(2, Y))
	_key(KEY_SPACE, true)
	_frames(s, 1)
	_check(not ctrl.holding(), "nothing can be grabbed in the countdown")
	_tap(s, KEY_LEFT)
	_check(ctrl.cursor_cell().x == 1, "but the cursor moves, as it does for swap")
	_key(KEY_SPACE, false)
	_frames(s, 2)
	_check(b.color == before, "and no blocks did")


func _test_move_during_a_finishing_carry_isnt_lost() -> void:
	var s := _state()
	_put_cursor(s, Vector2i(0, Y))
	_key(KEY_SPACE, true)
	_frames(s, 1)
	_tap(s, KEY_RIGHT)
	_tap(s, KEY_RIGHT)
	_key(KEY_SPACE, false)
	_tap(s, KEY_UP) # before the second swap has gone: swaps take a few frames
	_settle(s)
	_check(_bottom(s.boards[0])[2] == 1, "the carry finishes after letting go: %s" % [_bottom(s.boards[0])])
	_check(ctrl.cursor_cell() == Vector2i(2, Y - 1), "and the later move still happens: %s" % ctrl.cursor_cell())


func _test_stack_rising_carries_the_cursor() -> void:
	var s := _state()
	var b := s.boards[0]
	_put_cursor(s, Vector2i(3, 5))
	b.stop_t = 0
	b.rise = SimConst.ROW_UNITS - 2
	ctrl._last_rise = b.rise
	_frames(s, 2)
	_check(ctrl.cursor_cell() == Vector2i(3, 4), "the cursor stays on the blocks as they rise: %s" % ctrl.cursor_cell())
	_check(b.cursor_y == SimBoard.TOP + 4, "and the sim's agrees: %d" % (b.cursor_y - SimBoard.TOP))


func _test_small_rollback_of_rise_leaves_the_cursor() -> void:
	var s := _state()
	var b := s.boards[0]
	_put_cursor(s, Vector2i(3, 5))
	b.rise = 1000
	ctrl._last_rise = b.rise
	b.rise = 900
	_frames(s, 1)
	_check(ctrl.cursor_cell() == Vector2i(3, 5), "a rollback nudging rise back isn't the stack pushing up")
	ctrl._last_rise = 200
	b.rise = 200 + 2880 # a raise's worth of the longest frame the match allows
	_frames(s, 1)
	_check(ctrl.cursor_cell() == Vector2i(3, 5), "and a raise after a stall isn't one being undone")
	ctrl._last_rise = SimConst.ROW_UNITS - 100
	b.rise = 2780 # the same stall, across a row
	_frames(s, 1)
	_check(ctrl.cursor_cell() == Vector2i(3, 4), "but it can push up a row")
	ctrl._last_rise = 50
	b.rise = SimConst.ROW_UNITS - 50
	_frames(s, 1)
	_check(ctrl.cursor_cell() == Vector2i(3, 5), "and a rollback can undo that")


func _test_touch_press_carry_release() -> void:
	var s := _state()
	var b := s.boards[0]
	_touch(true, Vector2(0.5, Y + 0.5))
	_frames(s, 1)
	_check(ctrl.holding() and ctrl.cursor_cell() == Vector2i(0, Y), "a press grabs at once, with no delay to wait out")
	_drag(Vector2(1.5, Y + 0.5))
	_frames(s, 8)
	_drag(Vector2(2.5, Y + 0.5))
	_frames(s, 8)
	_check(_bottom(b) == [2, 3, 1, 4, 1, 2], "the block follows the finger: %s" % [_bottom(b)])
	_touch(false, Vector2(2.5, Y + 0.5))
	_frames(s, 1)
	_check(not ctrl.holding(), "lifting lets go")
	_settle(s)
	_check(ctrl.cursor_cell() == Vector2i(2, Y), "and the cursor stays where the block is")


func _test_touch_on_empty_follows_the_finger() -> void:
	var s := _state()
	var before := _bottom(s.boards[0])
	_touch(true, Vector2(1.5, 3.5))
	_frames(s, 1)
	_check(not ctrl.holding() and ctrl.cursor_cell() == Vector2i(1, 3), "a press on nothing moves the cursor there")
	_drag(Vector2(4.5, 7.5))
	_frames(s, 1)
	_check(ctrl.cursor_cell() == Vector2i(4, 7), "and it follows the finger")
	_touch(false, Vector2(4.5, 7.5))
	_settle(s)
	_check(ctrl.cursor_cell() == Vector2i(4, 7), "and stays when the finger lifts")
	_check(_bottom(s.boards[0]) == before, "having moved no blocks")


func _test_touch_off_the_board_stays_put() -> void:
	var s := _state()
	_touch(true, Vector2(3.5, Y + 0.5))
	_frames(s, 1)
	var before := _bottom(s.boards[0])
	ctrl.board_mapper = func(_p: Vector2) -> Vector2: return Vector2(-1, -1)
	_drag(Vector2(90, 90))
	_settle(s)
	ctrl.board_mapper = func(p: Vector2) -> Vector2: return p / 100.0
	_check(_bottom(s.boards[0]) == before, "a finger straying off the board doesn't throw the block to the wall")
	_touch(false, Vector2(3.5, Y + 0.5))
	_frames(s, 1)


func _test_touch_rising_row_raises() -> void:
	var s := _state()
	var sent := []
	_touch(true, Vector2(2.5, SimConst.H + 0.5))
	_frames(s, 3, sent)
	_touch(false, Vector2(2.5, SimConst.H + 0.5))
	_check(sent.all(func(m: int) -> bool: return m & SimConst.RAISE != 0), "holding the rising row raises")
	_check(not ctrl.holding(), "and holds no block")


func _hover(p: Vector2, device := 0, buttons := 0) -> void:
	var m := InputEventMouseMotion.new()
	m.position = p * 100.0
	m.device = device
	m.button_mask = buttons
	ctrl._input(m)


func _test_pointer_carries_the_cursor() -> void:
	var s := _state()
	var before := _bottom(s.boards[0])
	_hover(Vector2(5.5, 3.5))
	_frames(s, 1)
	_check(ctrl.cursor_cell() == Vector2i(5, 3), "the cursor goes to a floating pointer: %s" % ctrl.cursor_cell())
	_hover(Vector2(1.5, Y + 0.9))
	_frames(s, 1)
	_check(ctrl.cursor_cell() == Vector2i(1, Y), "and follows it: %s" % ctrl.cursor_cell())
	_hover(Vector2(1.5, SimConst.H + 0.5))
	_frames(s, 1)
	_check(ctrl.cursor_cell() == Vector2i(1, Y), "over the rising row, it stays on the bottom row")
	_frames(s, 8)
	_check(_bottom(s.boards[0]) == before, "and floating moves no blocks")
	_check(not ctrl.holding(), "or takes any")


func _test_pointer_ignores_what_isnt_floating() -> void:
	var s := _state()
	_put_cursor(s, Vector2i(2, 4))
	_hover(Vector2(5.5, 8.5), InputEvent.DEVICE_ID_EMULATION)
	_frames(s, 1)
	_check(ctrl.cursor_cell() == Vector2i(2, 4), "a finger's copied mouse movement isn't a pointer")
	_hover(Vector2(3.5, 6.5))
	_frames(s, 1)
	ctrl.board_mapper = func(_p: Vector2) -> Vector2: return Vector2(-1, -1)
	_hover(Vector2(90, 90))
	_frames(s, 1)
	ctrl.board_mapper = func(p: Vector2) -> Vector2: return p / 100.0
	_check(ctrl.cursor_cell() == Vector2i(3, 6), "off the board, the cursor stays where it was")
	_hover(Vector2(3.5, 6.5))
	var touch := InputEventScreenTouch.new()
	touch.pressed = true
	ctrl._input(touch)
	_put_cursor(s, Vector2i(0, 0))
	_check(ctrl.cursor_cell() == Vector2i.ZERO, "a real touch ends the floating")
	ctrl._input(_released(touch))


func _released(t: InputEventScreenTouch) -> InputEventScreenTouch:
	var up: InputEventScreenTouch = t.duplicate()
	up.pressed = false
	return up


func _test_keys_take_over_from_the_pointer() -> void:
	var s := _state()
	_hover(Vector2(3.5, 6.5))
	_frames(s, 1)
	_tap(s, KEY_LEFT)
	_frames(s, 2)
	_check(ctrl.cursor_cell() == Vector2i(2, 6), "a direction key moves the cursor off a still pointer, and it stays: %s" % ctrl.cursor_cell())
	_hover(Vector2(4.5, 6.5))
	_frames(s, 1)
	_check(ctrl.cursor_cell() == Vector2i(4, 6), "until the pointer moves again")


func _test_pointer_stays_with_a_rising_stack() -> void:
	var s := _state()
	_hover(Vector2(3.5, 6.2))
	_frames(s, 1)
	_check(ctrl.cursor_cell() == Vector2i(3, 6), "a pointer's cell, before anything rises")
	ctrl.board_mapper = func(p: Vector2) -> Vector2: return p / 100.0 + Vector2(0, 0.9)
	_frames(s, 1)
	ctrl.board_mapper = func(p: Vector2) -> Vector2: return p / 100.0
	_check(ctrl.cursor_cell() == Vector2i(3, 7), "the blocks moving under a still pointer move the cursor to what's under it")


func _test_pointer_carries_a_key_grab() -> void:
	var s := _state()
	var b := s.boards[0]
	_hover(Vector2(0.5, Y + 0.5))
	_frames(s, 1)
	_key(KEY_SPACE, true)
	_frames(s, 1)
	_check(ctrl.holding(), "the swap key takes the block under a floating cursor")
	_hover(Vector2(2.5, Y - 2.5))
	_settle(s)
	_check(_bottom(b) == [2, 3, 1, 4, 1, 2], "the pointer carries it, along its row: %s" % [_bottom(b)])
	_key(KEY_SPACE, false)
	_frames(s, 1)
	_check(not ctrl.holding(), "letting go of the key drops it")
	_frames(s, 1)
	_check(ctrl.cursor_cell() == Vector2i(2, Y - 3), "and the cursor goes back to the pointer: %s" % ctrl.cursor_cell())
	_settle(s)
	_check(_bottom(b) == [2, 3, 1, 4, 1, 2], "with the block left there")


func _test_pointer_waits_for_a_press() -> void:
	var s := _state()
	var b := s.boards[0]
	_hover(Vector2(3.5, 2.5))
	_frames(s, 1)
	_touch(true, Vector2(0.5, Y + 0.5)) # a click arrives as a copied touch
	_hover(Vector2(1.5, Y + 0.5), 0, MOUSE_BUTTON_MASK_LEFT)
	_drag(Vector2(1.5, Y + 0.5))
	_frames(s, 8)
	_check(_bottom(b) == [2, 1, 3, 4, 1, 2], "a press is a gesture, whatever the pointer does: %s" % [_bottom(b)])
	_touch(false, Vector2(1.5, Y + 0.5))
	_frames(s, 1)
	_check(ctrl.cursor_cell() == Vector2i(1, Y), "and afterwards the cursor is where the pointer ended up")


func _test_every_input_is_legal() -> void:
	var s := _state()
	var sent := []
	_put_cursor(s, Vector2i(5, Y))
	_key(KEY_SPACE, true)
	_frames(s, 2, sent)
	_key(KEY_LEFT, true)
	_frames(s, 30, sent)
	_key(KEY_LEFT, false)
	_key(KEY_UP, true)
	_frames(s, 4, sent)
	_key(KEY_UP, false)
	_key(KEY_SPACE, false)
	_frames(s, 2, sent)
	var legal := sent.all(func(m: int) -> bool: return m & ~SimConst.INPUT_BITS == 0)
	_check(legal, "every mask is one the server accepts")
	_check(sent.all(func(m: int) -> bool: return m & SimConst.DIRS == 0), "directions never reach the sim, which would move its cursor too")
	_check(sent.all(func(m: int) -> bool: return m & SimConst.TARGET != 0), "every sample places the cursor, so the two can't drift apart")
	_check(s.boards[0].cursor_x <= W - 2, "and the sim's cursor stays in range")


## Online, a swap shows on the board only after the input delay. Sending the next one before
## then would hit a block still mid-swap, and the sim would ignore it.
func _test_input_delay_paces_the_carry() -> void:
	var s := _state()
	var pending: Array[int] = [] # the masks in flight, three frames behind
	_put_cursor(s, Vector2i(0, Y))
	_key(KEY_SPACE, true)
	var swaps := 0
	for i in 40:
		if i in [2, 4, 6]: # taps two frames apart, faster than the block can swap
			_key(KEY_RIGHT, true)
		elif i in [3, 5, 7]:
			_key(KEY_RIGHT, false)
		now += 16
		var mask: int = ctrl.sample(s.boards[0])
		pending.append(mask)
		var delayed: int = pending.pop_front() if pending.size() > 3 else 0
		if mask & SimConst.SWAP:
			swaps += 1
		for t in SimConst.TICKS_PER_FRAME:
			s.step(delayed, 0)
	_key(KEY_SPACE, false)
	_frames(s, 8)
	_check(swaps == 3, "three quick taps carry three cells: %d swaps" % swaps)
	var bottom := _bottom(s.boards[0])
	_check(bottom.find(1) == swaps, "and none of the %d swaps was lost to the delay: %s" % [swaps, bottom])


func _test_rust_rules_agree() -> void:
	if not RustState.available():
		print("  skip the Rust rules aren't built")
		return
	var rust := RustState.make(5, true)
	var plain := SimState.create(5, true)
	var scripts: Array = [[1, KEY_DOWN], [1, KEY_DOWN], [1, KEY_DOWN], [190, KEY_SPACE], [1, KEY_RIGHT], [1, KEY_RIGHT], [12, KEY_SPACE], [1, KEY_UP]]
	var results := []
	for s: SimState in [plain, rust]:
		ctrl.reset_touch()
		now = 1000000
		var held := false
		var space := false
		for step: Array in scripts:
			for i in step[0]:
				_rust_frame(s)
			if step[1] == KEY_SPACE:
				space = not space
				_key(KEY_SPACE, space)
				_rust_frame(s)
				held = held or ctrl.holding()
			else:
				_key(step[1], true)
				_rust_frame(s)
				_key(step[1], false)
				_rust_frame(s)
		results.append([s.checksum(), ctrl.cursor_cell(), held])
	_check(results[0] == results[1], "the same keys do the same thing on both rules: %s" % [results])
	_check(results[0][2], "including a grab, so the Rust view shows what grabbing reads")


func _rust_frame(s: SimState) -> void:
	now += 16
	var input: int = ctrl.sample(s.boards[0])
	for t in SimConst.TICKS_PER_FRAME:
		s.step(input, 0)
	s.refresh_view()


func _test_swap_mode_unaffected() -> void:
	var s := _state()
	var b := s.boards[0]
	_check(ctrl.cursor_cell() == Vector2i(-1, -1), "the swap cursor has no cell of its own")
	_put_sim_cursor(s, 0)
	_tap(s, KEY_SPACE)
	_settle(s)
	_check(_bottom(b) == [2, 1, 3, 4, 1, 2], "and a tap of swap still swaps: %s" % [_bottom(b)])
	s = _state()
	b = s.boards[0]
	_hover(Vector2(3.5, Y + 0.5))
	_frames(s, 1)
	_check(b.cursor_x == 3 and b.cursor_y == SimBoard.ROWS - 1, "the two-block cursor follows a floating pointer: (%d, %d)" % [b.cursor_x, b.cursor_y - SimBoard.TOP])
	_tap(s, KEY_SPACE)
	_settle(s)
	_check(_bottom(b) == [1, 2, 3, 1, 4, 2], "and swap swaps there: %s" % [_bottom(b)])
	_hover(Vector2(5.5, Y + 0.5))
	_frames(s, 1)
	_check(b.cursor_x == W - 2, "fitting against the last column: %d" % b.cursor_x)
	_tap(s, KEY_LEFT)
	_frames(s, 3)
	_check(b.cursor_x == W - 3, "a direction key takes over from a still pointer: %d" % b.cursor_x)
	_hover(Vector2(1.5, Y + 0.5))
	_frames(s, 1)
	_check(b.cursor_x == 1, "until it moves again: %d" % b.cursor_x)
	for at: Array in [[2.1, 1], [2.45, 1], [2.55, 2], [2.9, 2], [0.1, 0], [5.9, W - 2]]:
		_hover(Vector2(at[0], Y + 0.5))
		_frames(s, 1)
		_check(b.cursor_x == at[1], "at %.2f the pair is centred on the nearest boundary: left %d" % [at[0], b.cursor_x])
	var sent := []
	_frames(s, 4, sent)
	_check(sent.all(func(m: int) -> bool: return m & SimConst.TARGET == 0), "and a still pointer sends nothing more: %s" % [sent])


func _put_sim_cursor(s: SimState, x: int) -> void:
	var b := s.boards[0]
	b.cursor_x = x
	b.cursor_y = SimBoard.ROWS - 1
