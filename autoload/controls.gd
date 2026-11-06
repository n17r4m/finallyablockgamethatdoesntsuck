extends Node
## Input: keyboard/gamepad bindings registered at runtime (keeps project.godot
## readable), plus touch — mouse too, via emulate_touch_from_mouse.
##
## Fingers are messy, so touch reads gestures, not raw cells:
##   tap    never leaves the slop zone          -> cursor moves there
##   flick  starts moving at once, then lifts   -> ONE swap, judged from the stroke
##          as a whole with its wobbly ends trimmed: the row is where the middle of
##          the stroke ran, the swap is at the cell boundary nearest its centre
##   carry  rests on a block, then moves        -> the block follows the finger,
##          swapping with each neighbour, with hysteresis at every boundary
## Holding the rising row below the stack raises. Everything comes out of
## sample() as the same one-int input the sim and netcode already carry.

## The defaults. A pad entry is a button, or Vector2i(axis, direction) for a stick or trigger.
## Saved bindings use the same values, in the "keys" and "pad" sections of the settings.
const BINDINGS := {
	"up": {"bit": SimConst.UP, "label": "Up", "keys": [KEY_UP, KEY_W],
			"pad": [JOY_BUTTON_DPAD_UP, Vector2i(JOY_AXIS_LEFT_Y, -1)]},
	"down": {"bit": SimConst.DOWN, "label": "Down", "keys": [KEY_DOWN, KEY_S],
			"pad": [JOY_BUTTON_DPAD_DOWN, Vector2i(JOY_AXIS_LEFT_Y, 1)]},
	"left": {"bit": SimConst.LEFT, "label": "Left", "keys": [KEY_LEFT, KEY_A],
			"pad": [JOY_BUTTON_DPAD_LEFT, Vector2i(JOY_AXIS_LEFT_X, -1)]},
	"right": {"bit": SimConst.RIGHT, "label": "Right", "keys": [KEY_RIGHT, KEY_D],
			"pad": [JOY_BUTTON_DPAD_RIGHT, Vector2i(JOY_AXIS_LEFT_X, 1)]},
	"swap": {"bit": SimConst.SWAP, "label": "Swap", "keys": [KEY_SPACE, KEY_X, KEY_K],
			"pad": [JOY_BUTTON_A, JOY_BUTTON_B]},
	"raise": {"bit": SimConst.RAISE, "label": "Raise", "keys": [KEY_C, KEY_L, KEY_SHIFT],
			"pad": [JOY_BUTTON_RIGHT_SHOULDER, JOY_BUTTON_LEFT_SHOULDER]},
}
const SLOTS := 3 # bindings an action can have, per device
const PAD_BUTTONS := {
	JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y",
	JOY_BUTTON_LEFT_SHOULDER: "LB", JOY_BUTTON_RIGHT_SHOULDER: "RB",
	JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3",
	JOY_BUTTON_DPAD_UP: "D-pad Up", JOY_BUTTON_DPAD_DOWN: "D-pad Down",
	JOY_BUTTON_DPAD_LEFT: "D-pad Left", JOY_BUTTON_DPAD_RIGHT: "D-pad Right",
}
const PAD_AXES := {
	Vector2i(JOY_AXIS_LEFT_X, -1): "LS Left", Vector2i(JOY_AXIS_LEFT_X, 1): "LS Right",
	Vector2i(JOY_AXIS_LEFT_Y, -1): "LS Up", Vector2i(JOY_AXIS_LEFT_Y, 1): "LS Down",
	Vector2i(JOY_AXIS_RIGHT_X, -1): "RS Left", Vector2i(JOY_AXIS_RIGHT_X, 1): "RS Right",
	Vector2i(JOY_AXIS_RIGHT_Y, -1): "RS Up", Vector2i(JOY_AXIS_RIGHT_Y, 1): "RS Down",
	Vector2i(JOY_AXIS_TRIGGER_LEFT, 1): "LT", Vector2i(JOY_AXIS_TRIGGER_RIGHT, 1): "RT",
}
const CAPTURE_AXIS := 0.6 # how far a stick must move to count when binding it
const TAP_HEIGHT := 48.0 # the usual minimum for a finger
const POPUP_ROW_GAP := 21 # makes dropdown rows about 44 tall, so all six fit on a landscape phone

# Gesture tuning, in cells and milliseconds.
const TAP_SLOP := 0.35 # movement under this is wobble, not a gesture
const CARRY_MARGIN := 0.25 # how far past a boundary a carried block must go to swap
const FLICK_TRIM := 0.2 # fraction of a flick's path ignored at each end
const FLICK_MIN_DX := 0.5 # shorter horizontal travel than this is a tap
const FLICK_VERTICAL := 1.2 # |dy| > this * |dx| is not a swap

enum { IDLE, PENDING, CARRY, FLICK, RAISING }

## A touch screen is the likely way to play, so say what fingers do and size things for them.
## Not DisplayServer.is_touchscreen_available(): emulate_touch_from_mouse makes that always true.
var touch_first: bool = (JavaScriptBridge.eval("'ontouchstart' in window", true) if OS.has_feature("web")
		else OS.has_feature("mobile"))
## Set by the match: screen position -> Vector2 in cell units (x right from the
## left edge, y down from the top visible row; y >= H is the rising row).
## Unset (or no local human) means touch is ignored.
var board_mapper := Callable()
## Resting this long before moving picks the block up; a setting.
var carry_delay_ms := 0
## Milliseconds; replaceable so tests can drive time.
var clock := func() -> int: return Time.get_ticks_msec()

var _mode := IDLE
var _finger := -1
var _down_at := 0
var _path := PackedVector2Array()
var _row := -1 # carried block's row, fixed at its first swap
var _grab := Vector2i(-1, -1) # the block being carried / the flick's swap, where it is now
var _steps := PackedInt32Array() # queued swaps as left-cell x, in _grab.y's row
var _swap_frame := false # last sample pressed swap; this one must release
var _last_rise := 0
var _presses := {} # action -> key/button presses no sample has delivered yet
var _down := 0 # actions down, as of the last event or sample
var _sent := 0 # the last sample


func _ready() -> void:
	carry_delay_ms = Config.get_value("controls", "carry_delay_ms")
	apply_bindings()
	# Not rebindable, so a player can always get out of a match and a menu.
	_add_fixed("leave", KEY_ESCAPE, JOY_BUTTON_START)
	# Godot's menu actions have no pad buttons. The match doesn't read these, so B can also swap.
	_add_fixed("ui_accept", null, JOY_BUTTON_A)
	_add_fixed("ui_cancel", null, JOY_BUTTON_B)


func _add_fixed(action: String, key: Variant, button: int) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	if key != null:
		InputMap.action_add_event(action, _key_event(key))
	InputMap.action_add_event(action, _pad_event(button))


## Puts the saved bindings into InputMap.
func apply_bindings() -> void:
	for action: String in BINDINGS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		InputMap.action_erase_events(action)
		InputMap.action_set_deadzone(action, Config.get_value("controls", "stick_deadzone"))
		for code: int in bindings("keys", action):
			InputMap.action_add_event(action, _key_event(code))
		for code: Variant in bindings("pad", action):
			InputMap.action_add_event(action, _pad_event(code))


func _key_event(code: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code as Key
	return ev


## On every pad: a phone's first device can be something other than the controller.
func _pad_event(code: Variant) -> InputEvent:
	var ev: InputEvent
	if code is Vector2i:
		ev = InputEventJoypadMotion.new()
		ev.axis = code.x
		ev.axis_value = code.y
	else:
		ev = InputEventJoypadButton.new()
		ev.button_index = code
	ev.device = -1
	return ev


## device is "keys" or "pad".
func bindings(device: String, action: String) -> Array:
	return Config.get_or(device, action, BINDINGS[action][device])


## Binds a key or button in a slot, or after the last binding if the slot is empty. Something
## that does two jobs is never what a player wants, so it leaves any other action it was on.
func bind(device: String, action: String, slot: int, code: Variant) -> void:
	var list := bindings(device, action).duplicate()
	if code in list:
		return
	for other: String in BINDINGS:
		if code in bindings(device, other):
			var theirs := bindings(device, other).duplicate()
			theirs.erase(code)
			Config.set_value(device, other, theirs)
	if slot < list.size():
		list[slot] = code
	else:
		list.append(code)
	Config.set_value(device, action, list)
	apply_bindings()


func unbind(device: String, action: String, slot: int) -> void:
	var list := bindings(device, action).duplicate()
	if slot < list.size():
		list.remove_at(slot)
		Config.set_value(device, action, list)
		apply_bindings()


func reset_bindings(device: String) -> void:
	Config.erase_section(device)
	apply_bindings()


## What a key or pad event would be bound as, or null if it can't be.
func binding_code(event: InputEvent, device: String) -> Variant:
	if device == "keys" and event is InputEventKey and event.pressed and not event.echo:
		return event.physical_keycode if event.physical_keycode != KEY_NONE else event.keycode
	if device == "pad" and event is InputEventJoypadButton and event.pressed:
		return event.button_index if event.button_index in PAD_BUTTONS else null
	if device == "pad" and event is InputEventJoypadMotion and absf(event.axis_value) >= CAPTURE_AXIS:
		var code := Vector2i(event.axis, signf(event.axis_value))
		return code if code in PAD_AXES else null
	return null


func binding_name(device: String, code: Variant) -> String:
	if device == "pad":
		return PAD_AXES.get(code, "?") if code is Vector2i else PAD_BUTTONS.get(code, "?")
	# What's printed on this player's key: the top row's first letter is A on a French keyboard.
	var knows_layout := DisplayServer.get_name() != "headless" and (OS.has_feature("linuxbsd")
			or OS.has_feature("windows") or OS.has_feature("macos"))
	return OS.get_keycode_string(DisplayServer.keyboard_get_keycode_from_physical(code) if knows_layout else code)


## A gamepad is plugged in, so that's what the hints should talk about.
func has_pad() -> bool:
	return not Input.get_connected_joypads().is_empty()


## There are keys or buttons to move a menu's focus with. Focus on a phone only gets in the way.
func navigates_by_focus() -> bool:
	return not touch_first or has_pad()


func leave_name() -> String:
	return "start" if has_pad() else "esc"


## The match's one line of how to play, from the current bindings.
func hint() -> String:
	var device := "pad" if has_pad() else "keys"
	var moves := PackedStringArray()
	for slot in SLOTS:
		var name := _moves_name(device, slot)
		if name != "":
			moves.append(name)
	var parts := PackedStringArray()
	if not moves.is_empty():
		parts.append("%s move" % "/".join(moves))
	for action: String in ["swap", "raise"]:
		var names := PackedStringArray()
		for code: Variant in bindings(device, action).slice(0, 2):
			names.append(binding_name(device, code))
		if not names.is_empty():
			parts.append("%s %s" % ["/".join(names), action])
	if device == "keys":
		parts.append("or drag blocks")
	parts.append("%s leave" % leave_name())
	return " · ".join(parts)


## Up, left, down and right of one slot, as one word when they make one: arrows, WASD, stick.
func _moves_name(device: String, slot: int) -> String:
	var names := PackedStringArray()
	for action: String in ["up", "left", "down", "right"]:
		var list := bindings(device, action)
		if slot >= list.size():
			return ""
		names.append(binding_name(device, list[slot]))
	if names == PackedStringArray(["Up", "Left", "Down", "Right"]):
		return "arrows"
	for prefix: String in ["D-pad", "LS"]:
		if Array(names).all(func(n: String) -> bool: return n.begins_with(prefix + " ")):
			return "stick" if prefix == "LS" else prefix
	if Array(names).all(func(n: String) -> bool: return n.length() == 1):
		return "".join(names)
	return "/".join(names)


## Makes a control big enough for a finger, on touch screens.
func size_for_fingers(control: Control) -> void:
	if touch_first:
		control.custom_minimum_size.y = TAP_HEIGHT
		if control is OptionButton:
			control.get_popup().add_theme_constant_override("v_separation", POPUP_ROW_GAP)


## How many project units make one density-independent pixel (1/160 inch, a CSS pixel on the
## web) at the project's normal stretch. Never below 1, so a big window just zooms in.
func dp_scale() -> float:
	var window := get_window()
	var fit := Vector2(window.size) / Vector2(window.content_scale_size)
	# On Android screen_get_scale() isn't the density: a Pixel 10 says 1.8 at 420 dpi (2.625).
	var native_mobile := OS.has_feature("mobile") and not OS.has_feature("web")
	var density := DisplayServer.screen_get_dpi() / 160.0 if native_mobile else DisplayServer.screen_get_scale()
	return maxf(1.0, density / minf(fit.x, fit.y))


## Keys and buttons: count presses as they happen, since one can start and end between samples.
## A press is the action going down, so a second key for a held action isn't one.
func _input(event: InputEvent) -> void:
	for action: String in BINDINGS:
		if not event.is_action(action):
			continue
		var bit: int = BINDINGS[action].bit
		if not Input.is_action_pressed(action):
			_down &= ~bit
		elif not _down & bit:
			_down |= bit
			_presses[action] = _presses.get(action, 0) + 1


func _unhandled_input(event: InputEvent) -> void:
	if not board_mapper.is_valid():
		return
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed and _finger == -1:
			_press(t.index, board_mapper.call(t.position))
		elif not t.pressed and t.index == _finger:
			_release(board_mapper.call(t.position))
	elif event is InputEventScreenDrag and (event as InputEventScreenDrag).index == _finger:
		_move(board_mapper.call((event as InputEventScreenDrag).position))


func _press(index: int, p: Vector2) -> void:
	if p.x < 0.0 or p.x >= SimConst.W or p.y < 0.0:
		return
	_finger = index
	_down_at = clock.call()
	_path = PackedVector2Array([p])
	_row = -1
	_mode = RAISING if p.y >= SimConst.H else PENDING
	if _mode == PENDING:
		_grab = Vector2i(int(p.x), int(p.y))


func _move(p: Vector2) -> void:
	_path.append(p)
	match _mode:
		PENDING:
			if p.distance_to(_path[0]) > TAP_SLOP:
				_mode = CARRY if clock.call() - _down_at >= carry_delay_ms else FLICK
				if _mode == CARRY:
					_carry_to(p)
		CARRY:
			_carry_to(p)


func _release(p: Vector2) -> void:
	_path.append(p)
	if _mode == FLICK:
		_flick()
	elif _mode == PENDING:
		_grab = Vector2i(int(_path[0].x), int(_path[0].y)) # tap: cursor goes where it landed
	_finger = -1
	_mode = IDLE


## Carry: walk the block toward the finger, one boundary (plus margin) at a time.
func _carry_to(p: Vector2) -> void:
	if _row < 0:
		# The row is decided where the finger actually is once it commits, not where it landed.
		_row = clampi(int(p.y), 0, SimConst.H - 1)
		_grab = Vector2i(clampi(int(_path[0].x), 0, SimConst.W - 1), _row)
	var at := _projected_x()
	while true:
		if p.x > at + 1 + CARRY_MARGIN and at < SimConst.W - 1:
			_steps.append(at)
			at += 1
		elif p.x < at - CARRY_MARGIN and at > 0:
			_steps.append(at - 1)
			at -= 1
		else:
			break


## Flick: one swap, read from the middle of the stroke.
func _flick() -> void:
	var mid := _trimmed(_path, FLICK_TRIM)
	var lo := INF
	var hi := -INF
	var y_sum := 0.0
	for q in mid:
		lo = minf(lo, q.x)
		hi = maxf(hi, q.x)
		y_sum += q.y
	var dx := _path[-1].x - _path[0].x
	var dy := _path[-1].y - _path[0].y
	var row := clampi(int(y_sum / mid.size()), 0, SimConst.H - 1)
	if absf(dx) < FLICK_MIN_DX or absf(dy) > FLICK_VERTICAL * absf(dx):
		_grab = Vector2i(clampi(int((lo + hi) / 2.0), 0, SimConst.W - 1), row) # not a swap: move the cursor
		return
	var left := clampi(roundi((lo + hi) / 2.0) - 1, 0, SimConst.W - 2)
	_grab = Vector2i(left, row)
	_steps = PackedInt32Array([left])


## The middle part of a path by arc length, dropping `trim` of it at each end.
static func _trimmed(path: PackedVector2Array, trim: float) -> PackedVector2Array:
	if path.size() < 3:
		return path
	var lengths := PackedFloat32Array([0.0])
	for i in range(1, path.size()):
		lengths.append(lengths[-1] + path[i].distance_to(path[i - 1]))
	var total := lengths[-1]
	if total <= 0.0:
		return path
	# Resample at fixed arc-length steps so slow stretches (many samples) don't outweigh fast ones.
	var out := PackedVector2Array()
	var steps := 16
	var j := 1
	for k in steps + 1:
		var s := total * (trim + (1.0 - 2.0 * trim) * k / steps)
		while j < lengths.size() - 1 and lengths[j] < s:
			j += 1
		var seg := lengths[j] - lengths[j - 1]
		var f := 0.0 if seg <= 0.0 else (s - lengths[j - 1]) / seg
		out.append(path[j - 1].lerp(path[j], clampf(f, 0.0, 1.0)))
	return out


## Where the carried block will be once the queued swaps are done.
func _projected_x() -> int:
	var at := _grab.x
	for left in _steps:
		at = left + 1 if at == left else left
	return at


## b: the local board, so gestures can follow the stack when it pushes up a row.
func sample(b: SimBoard = null) -> int:
	if b:
		if b.rise < _last_rise and _grab.y > 0:
			_grab.y -= 1
			if _row > 0:
				_row -= 1
		_last_rise = b.rise
	var mask := 0
	_down = 0 # from Input itself: losing window focus releases keys without any event
	for action: String in BINDINGS:
		var bit: int = BINDINGS[action].bit
		var on := Input.is_action_pressed(action)
		if on:
			_down |= bit
		# The sim sees a press when a bit goes from up to down, so a waiting press is sent
		# as down, and if the bit is already down it goes up for one sample first.
		var waiting: int = _presses.get(action, 0)
		if waiting > 0:
			on = not _sent & bit
			if on:
				_presses[action] = waiting - 1
		if on:
			mask |= bit
	_sent = mask | _touch_mask(b)
	return _sent


func _touch_mask(b: SimBoard) -> int:
	var mask := SimConst.RAISE if _mode == RAISING else 0
	if _swap_frame:
		_swap_frame = false
		return mask # release, so the next swap is a fresh press
	if not _steps.is_empty() and (b == null or _swappable(b, _steps[0], _grab.y)):
		var left := _steps[0]
		_steps.remove_at(0)
		_grab.x = left + 1 if _grab.x == left else left
		_swap_frame = true
		return mask | SimConst.target(left, _grab.y) | SimConst.SWAP
	if _grab.x >= 0 and (_finger != -1 or not _steps.is_empty() or _mode == IDLE and _grab.y >= 0):
		var t := SimConst.target(mini(_grab.x, SimConst.W - 2), _grab.y)
		if _finger == -1 and _steps.is_empty():
			_grab = Vector2i(-1, -1) # a finished tap/flick moves the cursor once
		return mask | t
	return mask


## Both cells of a swap are ready (the previous swap's animation has finished).
func _swappable(b: SimBoard, left: int, y: int) -> bool:
	for x: int in [left, left + 1]:
		var i := (SimConst.BUF + y) * SimConst.W + x
		if b.color[i] != 0 and (b.gid[i] != 0 or (b.st[i] != SimBoard.NORMAL and b.st[i] != SimBoard.LAND)):
			return false
	return true


## Forget any touch in progress and any presses not yet sampled (match start/end).
## A key still held stays held.
func reset_touch() -> void:
	_presses.clear()
	_sent = 0
	_mode = IDLE
	_finger = -1
	_grab = Vector2i(-1, -1)
	_steps.clear()
	_path.clear()
	_row = -1
	_swap_frame = false
