extends Node
## Input: keyboard/gamepad bindings registered at runtime (keeps project.godot
## readable), plus touch — mouse too, via emulate_touch_from_mouse.
##
## Touch: drag a block sideways and it follows your finger, swapping with each
## neighbour it passes (each swap waits for the last one's animation). Tap moves the
## cursor. Hold on the rising row below the stack to raise. Everything comes out
## of sample() as the same one-int input the sim and netcode already carry.

const BINDINGS := {
	"up": {"bit": SimConst.UP, "keys": [KEY_UP, KEY_W], "pad": [JOY_BUTTON_DPAD_UP]},
	"down": {"bit": SimConst.DOWN, "keys": [KEY_DOWN, KEY_S], "pad": [JOY_BUTTON_DPAD_DOWN]},
	"left": {"bit": SimConst.LEFT, "keys": [KEY_LEFT, KEY_A], "pad": [JOY_BUTTON_DPAD_LEFT]},
	"right": {"bit": SimConst.RIGHT, "keys": [KEY_RIGHT, KEY_D], "pad": [JOY_BUTTON_DPAD_RIGHT]},
	"swap": {"bit": SimConst.SWAP, "keys": [KEY_SPACE, KEY_X, KEY_K], "pad": [JOY_BUTTON_A, JOY_BUTTON_B]},
	"raise": {"bit": SimConst.RAISE, "keys": [KEY_C, KEY_L, KEY_SHIFT], "pad": [JOY_BUTTON_RIGHT_SHOULDER, JOY_BUTTON_LEFT_SHOULDER]},
}

## Set by the match: screen position -> Vector2i(column, visible row from the top),
## row H being the rising row. Unset (or no local human) means touch is ignored.
var board_mapper := Callable()

var _finger := -1 # touch index we're tracking
var _grab := Vector2i(-1, -1) # the block being dragged, where it is now
var _steps := PackedInt32Array() # queued swaps as left-cell x, in _grab.y's row
var _raising := false
var _swap_frame := false # last sample pressed swap; this one must release
var _last_rise := 0


func _ready() -> void:
	for action: String in BINDINGS:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for k: Key in BINDINGS[action].keys:
			var ev := InputEventKey.new()
			ev.physical_keycode = k
			InputMap.action_add_event(action, ev)
		for b: JoyButton in BINDINGS[action].pad:
			var ev := InputEventJoypadButton.new()
			ev.button_index = b
			InputMap.action_add_event(action, ev)


func _unhandled_input(event: InputEvent) -> void:
	if not board_mapper.is_valid():
		return
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed and _finger == -1:
			var c: Vector2i = board_mapper.call(t.position)
			if c.x < 0 or c.x >= SimConst.W or c.y < 0:
				return
			_finger = t.index
			_raising = c.y >= SimConst.H
			_grab = c if not _raising else Vector2i(-1, -1)
			_steps.clear()
		elif not t.pressed and t.index == _finger:
			_finger = -1
			_raising = false
	elif event is InputEventScreenDrag and (event as InputEventScreenDrag).index == _finger and _grab.x >= 0:
		var c: Vector2i = board_mapper.call((event as InputEventScreenDrag).position)
		var x := clampi(c.x, 0, SimConst.W - 1)
		var at := _grab.x
		if not _steps.is_empty():
			at = _projected_x()
		while x != at:
			var dir := 1 if x > at else -1
			_steps.append(mini(at, at + dir))
			at += dir


## Where the grabbed block will be once the queued swaps are done.
func _projected_x() -> int:
	var at := _grab.x
	for left in _steps:
		at = left + 1 if at == left else left
	return at


## b: the local board, so a drag can follow the stack when it pushes up a row.
func sample(b: SimBoard = null) -> int:
	if b:
		if b.rise < _last_rise and _grab.y > 0:
			_grab.y -= 1
		_last_rise = b.rise
	var mask := 0
	for action: String in BINDINGS:
		if Input.is_action_pressed(action):
			mask |= BINDINGS[action].bit
	return mask | _touch_mask(b)


func _touch_mask(b: SimBoard) -> int:
	var mask := SimConst.RAISE if _raising else 0
	if _swap_frame:
		_swap_frame = false
		return mask # release, so the next swap is a fresh press
	if not _steps.is_empty() and (b == null or _swappable(b, _steps[0], _grab.y)):
		var left := _steps[0]
		_steps.remove_at(0)
		_grab.x = left + 1 if _grab.x == left else left
		_swap_frame = true
		return mask | SimConst.target(left, _grab.y) | SimConst.SWAP
	if _finger != -1 and _grab.x >= 0:
		return mask | SimConst.target(mini(_grab.x, SimConst.W - 2), _grab.y)
	return mask


## Both cells of a swap are ready (the previous swap's animation has finished).
func _swappable(b: SimBoard, left: int, y: int) -> bool:
	for x: int in [left, left + 1]:
		var i := (SimConst.BUF + y) * SimConst.W + x
		if b.color[i] != 0 and (b.gid[i] != 0 or (b.st[i] != SimBoard.NORMAL and b.st[i] != SimBoard.LAND)):
			return false
	return true


## Forget any touch in progress (match start/end).
func reset_touch() -> void:
	_finger = -1
	_grab = Vector2i(-1, -1)
	_steps.clear()
	_raising = false
	_swap_frame = false
