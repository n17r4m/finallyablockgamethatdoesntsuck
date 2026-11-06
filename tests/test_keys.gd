extends SceneTree
## Keyboard input through the real Input singleton, InputMap and Controls autoload. Every
## press has to reach the sim, however short, and a held key has to stay a plain hold.
##   godot --headless --path . -s tests/test_keys.gd

const SWAP := SimConst.SWAP
const LEFT := SimConst.LEFT

var _failed := 0
var ctrl: Node


func _initialize() -> void:
	# Autoloads aren't ready until the first frame.
	await process_frame
	ctrl = root.get_node("Controls")
	_test_tap_between_samples()
	_test_two_taps_between_samples()
	_test_retap_of_held_key()
	_test_hold_is_unchanged()
	_test_second_binding_is_not_a_press()
	_test_presses_before_a_match_are_forgotten()
	_test_key_held_into_a_match_stays_held()
	_test_tap_moves_the_cursor_once()
	_test_tap_swaps_on_a_one_tick_frame()
	_test_tap_survives_a_stall()
	print("PASS" if _failed == 0 else "FAIL (%d)" % _failed)
	quit(0 if _failed == 0 else 1)


func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_failed += 1


## Send a key through Input as the OS would, and let it reach the nodes.
func _key(code: Key, pressed: bool, echo := false) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.pressed = pressed
	ev.echo = echo
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _tap(code: Key) -> void:
	_key(code, true)
	_key(code, false)


func _samples(n: int, bit: int) -> Array[bool]:
	var out: Array[bool] = []
	for i in n:
		out.append(ctrl.sample() & bit != 0)
	return out


func _test_tap_between_samples() -> void:
	ctrl.reset_touch()
	_tap(KEY_SPACE)
	var got := _samples(3, SWAP)
	_check(got == [true, false, false], "a tap between samples is one press: %s" % [got])


func _test_two_taps_between_samples() -> void:
	ctrl.reset_touch()
	_tap(KEY_SPACE)
	_tap(KEY_SPACE)
	var got := _samples(5, SWAP)
	_check(got == [true, false, true, false, false], "two taps between samples are two presses: %s" % [got])


func _test_retap_of_held_key() -> void:
	ctrl.reset_touch()
	_key(KEY_SPACE, true)
	var first := _samples(1, SWAP)
	_key(KEY_SPACE, false)
	_key(KEY_SPACE, true)
	var got := first + _samples(3, SWAP)
	_key(KEY_SPACE, false)
	got += _samples(1, SWAP)
	_check(got == [true, false, true, true, false], "release and re-press between samples shows the sim a new press: %s" % [got])


func _test_hold_is_unchanged() -> void:
	ctrl.reset_touch()
	var before := _samples(2, LEFT)
	_key(KEY_LEFT, true)
	var held := _samples(3, LEFT)
	_key(KEY_LEFT, true, true) # the OS repeats a held key
	held += _samples(3, LEFT)
	_key(KEY_LEFT, false)
	var after := _samples(2, LEFT)
	_check(before == [false, false] and not held.has(false) and after == [false, false],
			"a held key is down from press to release, through key repeat: %s %s %s" % [before, held, after])


func _test_second_binding_is_not_a_press() -> void:
	ctrl.reset_touch()
	_key(KEY_SPACE, true)
	var got := _samples(2, SWAP)
	_key(KEY_X, true) # also swap: no new press while the action is already down
	got += _samples(2, SWAP)
	_key(KEY_SPACE, false)
	got += _samples(2, SWAP) # X still holds it
	_key(KEY_X, false)
	got += _samples(1, SWAP)
	_check(got == [true, true, true, true, true, true, false], "a second binding of a held action stays one hold: %s" % [got])


func _test_presses_before_a_match_are_forgotten() -> void:
	ctrl.reset_touch()
	_tap(KEY_SPACE) # picking a menu item
	ctrl.reset_touch() # the match starts
	var got := _samples(2, SWAP)
	_check(got == [false, false], "a press from the menu doesn't carry into the match: %s" % [got])


func _test_key_held_into_a_match_stays_held() -> void:
	ctrl.reset_touch()
	_key(KEY_LEFT, true)
	ctrl.reset_touch() # the match starts
	var got := _samples(2, LEFT)
	_key(KEY_LEFT, false)
	got += _samples(1, LEFT)
	_tap(KEY_LEFT)
	got += _samples(2, LEFT)
	_check(got == [true, true, false, true, false], "a key held into a match is held, and taps fine after: %s" % [got])


## Solo board with no stack in the way, past the countdown.
func _state() -> SimState:
	var s := SimState.create(5, true)
	s.tick = SimConst.COUNTDOWN_TICKS
	s.boards[0].clear_all()
	s.boards[0].stop_t = 1 << 30
	return s


func _test_tap_moves_the_cursor_once() -> void:
	ctrl.reset_touch()
	var s := _state()
	var b := s.boards[0]
	var x := b.cursor_x
	_tap(KEY_LEFT)
	for f in 30:
		var input: int = ctrl.sample(b)
		for t in SimConst.TICKS_PER_FRAME:
			s.step(input, 0)
	_check(b.cursor_x == x - 1, "the sim moves the cursor once for a tap: %d -> %d" % [x, b.cursor_x])


## A display fast enough to sample every tick: the press is down for a single tick.
func _test_tap_swaps_on_a_one_tick_frame() -> void:
	ctrl.reset_touch()
	var s := _state()
	var b := s.boards[0]
	var at := (b.cursor_y) * SimConst.W + b.cursor_x
	b.color[at] = 1
	_tap(KEY_SPACE)
	s.step(ctrl.sample(b), 0)
	_check(b.color[at] == 0 and b.color[at + 1] == 1, "the sim swaps for a press that lasts one tick")


## The same loop as scenes/match.gd, with the peer gone quiet so the session stalls.
func _test_tap_survives_a_stall() -> void:
	ctrl.reset_touch()
	var session := RollbackSession.new(5, 0, 24)
	var frame := func() -> void:
		if session.input_open():
			session.set_local_input(ctrl.sample(session.state.boards[0]))
		session.advance(SimConst.TICKS_PER_FRAME)
	while session.input_open():
		frame.call()
	var stalled_at := session.state.tick
	_tap(KEY_SPACE)
	for f in 5:
		frame.call()
	var still_stalled := session.state.tick == stalled_at and not session.input_open()
	var recorded := session.input_at(0, stalled_at + session.input_delay + 1) & SWAP
	session.receive({
		"f": stalled_at + 600, "t": PackedInt64Array(), "m": PackedInt32Array(), "a": -1,
		"c": {}, "s": stalled_at, "v": 0,
	})
	var ends_at := stalled_at + 120
	while session.state.tick < ends_at:
		frame.call()
	var ticks: PackedInt64Array = session.input_log(0, ends_at)[0]
	var masks: PackedInt32Array = session.input_log(0, ends_at)[1]
	var seen := 0
	for i in masks.size():
		if masks[i] & SWAP:
			seen += 1
	_check(still_stalled and recorded == 0 and seen == 1 and ticks.size() == 2,
			"a tap during a stall reaches the sim once the session resumes: stalled=%s changes=%s %s" % [still_stalled, ticks, masks])
