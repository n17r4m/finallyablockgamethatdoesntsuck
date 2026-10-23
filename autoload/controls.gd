extends Node
## Registers default bindings at runtime (keeps project.godot readable) and
## samples them into the sim's input bitmask.

const BINDINGS := {
	"up": {"bit": SimConst.UP, "keys": [KEY_UP, KEY_W], "pad": [JOY_BUTTON_DPAD_UP]},
	"down": {"bit": SimConst.DOWN, "keys": [KEY_DOWN, KEY_S], "pad": [JOY_BUTTON_DPAD_DOWN]},
	"left": {"bit": SimConst.LEFT, "keys": [KEY_LEFT, KEY_A], "pad": [JOY_BUTTON_DPAD_LEFT]},
	"right": {"bit": SimConst.RIGHT, "keys": [KEY_RIGHT, KEY_D], "pad": [JOY_BUTTON_DPAD_RIGHT]},
	"swap": {"bit": SimConst.SWAP, "keys": [KEY_SPACE, KEY_X, KEY_K], "pad": [JOY_BUTTON_A, JOY_BUTTON_B]},
	"raise": {"bit": SimConst.RAISE, "keys": [KEY_C, KEY_L, KEY_SHIFT], "pad": [JOY_BUTTON_RIGHT_SHOULDER, JOY_BUTTON_LEFT_SHOULDER]},
}


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


func sample() -> int:
	var mask := 0
	for action: String in BINDINGS:
		if Input.is_action_pressed(action):
			mask |= BINDINGS[action].bit
	return mask
