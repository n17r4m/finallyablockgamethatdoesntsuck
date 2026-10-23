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

const BINDINGS := {
	"up": {"bit": SimConst.UP, "keys": [KEY_UP, KEY_W], "pad": [JOY_BUTTON_DPAD_UP]},
	"down": {"bit": SimConst.DOWN, "keys": [KEY_DOWN, KEY_S], "pad": [JOY_BUTTON_DPAD_DOWN]},
	"left": {"bit": SimConst.LEFT, "keys": [KEY_LEFT, KEY_A], "pad": [JOY_BUTTON_DPAD_LEFT]},
	"right": {"bit": SimConst.RIGHT, "keys": [KEY_RIGHT, KEY_D], "pad": [JOY_BUTTON_DPAD_RIGHT]},
	"swap": {"bit": SimConst.SWAP, "keys": [KEY_SPACE, KEY_X, KEY_K], "pad": [JOY_BUTTON_A, JOY_BUTTON_B]},
	"raise": {"bit": SimConst.RAISE, "keys": [KEY_C, KEY_L, KEY_SHIFT], "pad": [JOY_BUTTON_RIGHT_SHOULDER, JOY_BUTTON_LEFT_SHOULDER]},
}

# Gesture tuning, in cells and milliseconds.
const TAP_SLOP := 0.35 # movement under this is wobble, not a gesture
const HOLD_TO_CARRY_MS := 110 # resting this long before moving picks the block up
const CARRY_MARGIN := 0.25 # how far past a boundary a carried block must go to swap
const FLICK_TRIM := 0.2 # fraction of a flick's path ignored at each end
const FLICK_MIN_DX := 0.5 # shorter horizontal travel than this is a tap
const FLICK_VERTICAL := 1.2 # |dy| > this * |dx| is not a swap

enum { IDLE, PENDING, CARRY, FLICK, RAISING }

## Set by the match: screen position -> Vector2 in cell units (x right from the
## left edge, y down from the top visible row; y >= H is the rising row).
## Unset (or no local human) means touch is ignored.
var board_mapper := Callable()
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
				_mode = CARRY if clock.call() - _down_at >= HOLD_TO_CARRY_MS else FLICK
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
	for action: String in BINDINGS:
		if Input.is_action_pressed(action):
			mask |= BINDINGS[action].bit
	return mask | _touch_mask(b)


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


## Forget any touch in progress (match start/end).
func reset_touch() -> void:
	_mode = IDLE
	_finger = -1
	_grab = Vector2i(-1, -1)
	_steps.clear()
	_path.clear()
	_row = -1
	_swap_frame = false
