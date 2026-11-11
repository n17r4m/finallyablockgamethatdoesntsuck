extends Node
## Input: keyboard/gamepad bindings registered at runtime (keeps project.godot
## readable), plus touch — mouse too, via emulate_touch_from_mouse.
##
## Fingers are messy, so touch reads gestures, not raw cells:
##   tap    never leaves the slop zone          -> swaps the two blocks either side of the
##          nearest cell boundary, and the cursor goes there. A floating pointer aims the same way
##   flick  starts moving at once, then lifts   -> ONE swap, judged from the stroke
##          as a whole with its wobbly ends trimmed: the row is where the middle of
##          the stroke ran, the swap is at the cell boundary nearest its centre
##   carry  rests on a block, then moves        -> the block follows the finger,
##          swapping with each neighbour, with hysteresis at every boundary
## Holding the rising row below the stack raises. Everything comes out of
## sample() as the same one-int input the sim and netcode already carry.
##
## The grab cursor (a setting) is one block wide, and lives here rather than in the sim. A press
## takes the block under it, moving carries the block along its row, and letting go ends it: a
## finger or mouse grabs where it lands, a key or button grabs while the swap binding is held.
## It reaches the sim as the same placements and swaps, so the rules, replays, netcode and
## referee can't tell which cursor a player uses. An opponent sees a two-block cursor around it.
##
## A pointer that can rest over the board without pressing, like a mouse, carries either cursor
## with it, until a direction key or button takes over. Fingers aren't there between touches.

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
const NO_CELL := Vector2i(-1, -1)
## Long ago, so whatever waits on it is ready.
const LONG_AGO_MS := -1000000
## The board shows a swap only after any input delay, so a carried block isn't judged until then.
const LET_GO_CHECK_MS := 150

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
## One-block cursor with grab and release, instead of the two-block cursor; a setting.
var grab_mode := false
## "keys", "pad", "mouse" or "touch" once the player has used one: see hint_device().
var last_device := ""
## Inputs reach the board late, as they do online, so the board can't say when a swap has finished.
var input_is_delayed := false
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
var _pairs: Array[Vector2i] = [] # tapped or flicked pairs waiting their turn, left cell and row
var _stays_on_pair := false # the swap in progress is one: the cursor stays on it, not on one block
var _last_rise := 0
var _rules := SimRules.shared_standard() # the rules of the board last sampled
var _presses := {} # action -> key/button presses no sample has delivered yet
var _down := 0 # actions down, as of the last event or sample
var _sent := 0 # the last sample
var _held := false # grab cursor: a block is in hand, at _grab
var _keys_before := 0 # grab cursor: the keys of the last sample
var _repeat_at := 0 # grab cursor: when a held direction next moves
var _after_steps := Vector2i.ZERO # grab cursor: moves made while a let-go block finished moving
var _step_at := LONG_AGO_MS # when the last gesture's swap was sent
var _step_cell := NO_CELL # and its left cell and row
var _view: SimBoard # the board of the last sample
var _pointer := Vector2.ZERO # where a floating pointer is, on screen
var _floating := false # the cursor is following it
var _floated_to := NO_CELL # two-block cursor: the cell it last sent the sim's cursor to


func _ready() -> void:
	carry_delay_ms = Config.get_value("controls", "carry_delay_ms")
	grab_mode = Config.get_value("controls", "cursor") == "grab"
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


## A gamepad is plugged in.
func has_pad() -> bool:
	return not Input.get_connected_joypads().is_empty()


## What the hints should talk about: whatever the player used last, or else the likely way to play.
func hint_device() -> String:
	if last_device != "":
		return last_device
	if touch_first:
		return "touch"
	return "pad" if has_pad() else "keys"


## There are keys or buttons to move a menu's focus with. Focus on a phone only gets in the way.
func navigates_by_focus() -> bool:
	return not touch_first or has_pad()


func leave_name() -> String:
	return "start" if hint_device() == "pad" else "esc"


## How the player taps on the screen, in hints. Empty for keys and buttons.
func tap_word() -> String:
	match hint_device():
		"touch":
			return "tap"
		"mouse":
			return "click"
	return ""


## How to play, from the current cursor and bindings, as parts to join with " · ".
func hint() -> String:
	var device := hint_device()
	if device == "touch" or device == "mouse":
		var hold := "hold the bottom row to raise"
		if grab_mode:
			return "drag a block to carry it · %s elsewhere to move the cursor · %s" % [tap_word(), hold]
		return "%s between two blocks to swap them · drag a block to carry it · %s" % [tap_word(), hold]
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
			var word := "hold to grab" if action == "swap" and grab_mode else action
			parts.append("%s %s" % ["/".join(names), word])
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
	_note_device(event)
	if event is InputEventMouseMotion and event.device != InputEvent.DEVICE_ID_EMULATION:
		point_at(event.position)
	elif event is InputEventScreenTouch and event.device != InputEvent.DEVICE_ID_EMULATION:
		_stop_floating()
	for action: String in BINDINGS:
		if not event.is_action(action):
			continue
		var bit: int = BINDINGS[action].bit
		if not Input.is_action_pressed(action):
			_down &= ~bit
		elif not _down & bit:
			_down |= bit
			_presses[action] = _presses.get(action, 0) + 1
			if bit & SimConst.DIRS:
				_stop_floating()


## A floating pointer has moved here: a mouse now, and anything else that can hover, like a VR
## controller's ray, later. The cursor follows it from the next sample.
func point_at(screen: Vector2) -> void:
	_pointer = screen
	_floating = true


func _stop_floating() -> void:
	_floating = false
	_floated_to = NO_CELL


## Every sample, not only when it moves, so the cursor stays under a pointer as the stack rises.
## In grab mode, a block taken with the swap key can be carried by the pointer too. A press on the
## pointer is a gesture, which has the cursor already.
func _follow_pointer() -> void:
	if not _floating or _finger != -1 or not board_mapper.is_valid():
		return
	var p: Vector2 = board_mapper.call(_pointer)
	if p == Vector2(NO_CELL):
		return
	if holding():
		_carry_to(p)
		return
	if not _steps.is_empty() or not _pairs.is_empty():
		return
	if grab_mode:
		_grab = Vector2i(clampi(int(p.x), 0, SimConst.W - 1), clampi(int(p.y), 0, SimConst.H - 1))
		return
	var pair := _pair_at(p)
	if pair != _floated_to: # the sim's cursor is only told when it should change
		_grab = pair
		_floated_to = pair


## Each mouse press also arrives as a touch and each touch as a mouse press, marked as copies.
func _note_device(event: InputEvent) -> void:
	if event is InputEventKey:
		if event.pressed:
			last_device = "keys"
	elif event is InputEventJoypadButton:
		if event.pressed:
			last_device = "pad"
	elif event is InputEventJoypadMotion:
		if absf(event.axis_value) >= CAPTURE_AXIS:
			last_device = "pad"
	elif event.device == InputEvent.DEVICE_ID_EMULATION:
		pass
	elif event is InputEventMouseButton:
		if event.pressed:
			last_device = "mouse"
	elif event is InputEventScreenTouch:
		if event.pressed:
			last_device = "touch"


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
		if grab_mode:
			_grab = Vector2i(int(p.x), int(p.y))
		elif _steps.is_empty(): # otherwise those steps still need their row
			_grab = _pair_at(p)
		if grab_mode:
			_steps.clear()
			_after_steps = Vector2i.ZERO
			_take_hold()


func _move(p: Vector2) -> void:
	_path.append(p)
	if grab_mode and _mode == PENDING:
		if p == Vector2(NO_CELL): # off the board, so nowhere to follow it to
			return
		if _held:
			_carry_to(p)
		else:
			_grab = Vector2i(clampi(int(p.x), 0, SimConst.W - 1), clampi(int(p.y), 0, SimConst.H - 1))
		return
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
	_held = false
	if grab_mode:
		_finger = -1
		_mode = IDLE
		return
	if _mode == FLICK:
		_flick()
	elif _mode == PENDING: # tap
		_pairs.append(_pair_at(_path[0]))
	_finger = -1
	_mode = IDLE


## The two-block cursor that a point on the board aims at: the two cells either side of the
## nearest boundary between cells, on that row, so the point is always in the pair's middle half.
func _pair_at(p: Vector2) -> Vector2i:
	return Vector2i(clampi(roundi(p.x) - 1, 0, SimConst.W - 2), clampi(int(p.y), 0, SimConst.H - 1))


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
	_pairs.append(Vector2i(left, row))


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
static func _ms(ticks: int) -> int:
	return ticks * 1000 / SimConst.TICK_HZ


## How far apart a carry's swaps go. The block has to have finished the last one, and with input
## delay the board can't show that in time. The delay never changes, so spacing them is enough.
func _step_ms() -> int:
	return _ms(_rules.swap) + 17


func _projected_x() -> int:
	var at := _grab.x
	for left in _steps:
		at = left + 1 if at == left else left
	return at


## b: the local board, so gestures can follow the stack when it pushes up a row.
func sample(b: SimBoard = null) -> int:
	if b != null and b.rules != null:
		_rules = b.rules
	_view = b
	if b:
		_follow_rise(b)
	_follow_pointer()
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
	if grab_mode:
		_sent = mask
		return _grab_mask(mask, b)
	_sent = mask | _touch_mask(b)
	return _sent


## Gestures hold a row, so it has to move when the stack does. Rise drops when the stack pushes up
## a row, by less if a raise after a stall made up much of that row in one frame, and jumps by
## nearly a row if a rollback undoes a push. Otherwise a rollback only nudges it, either way.
func _follow_rise(b: SimBoard) -> void:
	var change := b.rise - _last_rise
	_last_rise = b.rise
	var rows := -1 if change < -b.rules.row_units / 4 else (1 if change > b.rules.row_units * 3 / 4 else 0)
	if rows != 0 and _grab.y >= 0:
		_grab.y = clampi(_grab.y + rows, 0, SimConst.H - 1)
		if _row >= 0:
			_row = _grab.y


## The one-block cursor, or (-1, -1) if the player is using the two-block one.
func cursor_cell() -> Vector2i:
	return _grab if grab_mode else NO_CELL


func holding() -> bool:
	return grab_mode and _held


## Keys and a finger, into a placement every sample and a swap for each step of a carry.
func _grab_mask(keys: int, b: SimBoard) -> int:
	if _grab == NO_CELL:
		if b == null:
			return keys & SimConst.RAISE
		_grab = Vector2i(b.cursor_x, b.cursor_y - SimBoard.TOP)
		_row = -1
	var now: int = clock.call()
	var pressed := keys & ~_keys_before
	if pressed & SimConst.SWAP and _finger == -1:
		_take_hold()
	elif _keys_before & ~keys & SimConst.SWAP and _finger == -1:
		_held = false
	_move_by_keys(keys, pressed, now)
	_keys_before = keys
	var mask := keys & SimConst.RAISE
	if _mode == RAISING:
		mask |= SimConst.RAISE
	if _swap_frame:
		_swap_frame = false # release, so the next swap is a fresh press
		return mask | SimConst.target(_grab.x, _grab.y)
	if not _steps.is_empty():
		var left := _steps[0]
		if b != null and _refuses(b, left, _grab.y):
			_steps.clear()
		elif now - _step_at >= _step_ms() and (b == null or _swappable(b, left, _grab.y)):
			_steps.remove_at(0)
			_grab.x = left + 1 if _grab.x == left else left
			_step_at = now
			_swap_frame = true
			return mask | SimConst.target(left, _grab.y) | SimConst.SWAP
	if _steps.is_empty() and _after_steps != Vector2i.ZERO:
		_shift_cursor(_after_steps)
		_after_steps = Vector2i.ZERO
	# A block that drops or matches is out of the player's hand.
	if _held and _steps.is_empty() and b != null and now - _step_at >= LET_GO_CHECK_MS and not _can_hold(b, _grab):
		_held = false
	return mask | SimConst.target(_grab.x, _grab.y)


func _move_by_keys(keys: int, pressed: int, now: int) -> void:
	var moves := pressed & SimConst.DIRS
	if moves != 0:
		_repeat_at = now + _ms(_rules.repeat_delay)
	elif keys & SimConst.DIRS != 0 and now >= _repeat_at:
		moves = keys & SimConst.DIRS
		_repeat_at = now + _ms(_rules.repeat_rate)
	var dx := (1 if moves & SimConst.RIGHT else 0) - (1 if moves & SimConst.LEFT else 0)
	var dy := (1 if moves & SimConst.DOWN else 0) - (1 if moves & SimConst.UP else 0)
	if _held:
		var at := _projected_x()
		var to := clampi(at + dx, 0, SimConst.W - 1)
		if to != at:
			_steps.append(mini(at, to))
	elif not _steps.is_empty():
		_after_steps += Vector2i(dx, dy)
	else:
		_shift_cursor(Vector2i(dx, dy))


func _shift_cursor(by: Vector2i) -> void:
	_grab = Vector2i(clampi(_grab.x + by.x, 0, SimConst.W - 1), clampi(_grab.y + by.y, 0, SimConst.H - 1))


## Takes the block at the cursor, if there is one to take. Nothing moves during the countdown.
func _take_hold() -> void:
	_held = _view == null or (_view.age > 0 and _can_hold(_view, _grab))
	_row = _grab.y


## A plain block, and not one on its way down or out. One mid-swap is fine: it's about to rest.
func _can_hold(b: SimBoard, at: Vector2i) -> bool:
	var i := (SimConst.BUF + at.y) * SimConst.W + at.x
	return (b.color[i] != 0 and b.gid[i] == 0
			and b.st[i] != SimBoard.HOVER and b.st[i] != SimBoard.FALL and b.st[i] != SimBoard.MATCHED)


## This swap won't become possible by waiting a moment for an animation.
func _refuses(b: SimBoard, left: int, y: int) -> bool:
	for x: int in [left, left + 1]:
		var i := (SimConst.BUF + y) * SimConst.W + x
		if b.color[i] != 0 and (b.gid[i] != 0 or b.st[i] == SimBoard.MATCHED):
			return true
	return false


func _touch_mask(b: SimBoard) -> int:
	var mask := SimConst.RAISE if _mode == RAISING else 0
	if _swap_frame:
		_swap_frame = false
		return mask # release, so the next swap is a fresh press
	if _steps.is_empty() and not _pairs.is_empty():
		_grab = _pairs.pop_front()
		_steps = PackedInt32Array([_grab.x])
		_stays_on_pair = true
	if not _steps.is_empty() and b != null and _refuses(b, _steps[0], _grab.y):
		_steps.clear() # waiting wouldn't help, and it would go off much later
	if not _steps.is_empty() and not _too_soon(_steps[0], _grab.y) and (b == null or _swappable(b, _steps[0], _grab.y)):
		var left := _steps[0]
		_steps.remove_at(0)
		var row := _grab.y
		_step_at = clock.call()
		_step_cell = Vector2i(left, row)
		_grab.x = left + 1 if _grab.x == left else left
		if _stays_on_pair:
			_stays_on_pair = false
			_grab = NO_CELL # the cursor is on the pair now, and the sim keeps it there
		_swap_frame = true
		return mask | SimConst.target(left, row) | SimConst.SWAP
	if _grab.x >= 0 and (_finger != -1 or not _steps.is_empty() or _mode == IDLE and _grab.y >= 0):
		var t := SimConst.target(mini(_grab.x, SimConst.W - 2), _grab.y)
		if _finger == -1 and _steps.is_empty():
			_grab = Vector2i(-1, -1) # a finished tap/flick moves the cursor once
		return mask | t
	return mask


## With delayed input the board still shows these blocks at rest when they're already swapping,
## and the sim ignores a swap of a block mid-swap. A swap elsewhere has nothing to wait for.
func _too_soon(left: int, y: int) -> bool:
	return (input_is_delayed and y == _step_cell.y and absi(left - _step_cell.x) <= 1
			and clock.call() - _step_at < _step_ms())


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
	_grab = NO_CELL
	_steps.clear()
	_path.clear()
	_row = -1
	_swap_frame = false
	_stays_on_pair = false
	_pairs.clear()
	_held = false
	_keys_before = 0
	_after_steps = Vector2i.ZERO
	_step_at = LONG_AGO_MS
	_step_cell = NO_CELL
	_last_rise = 0
	_view = null
	_stop_floating()
