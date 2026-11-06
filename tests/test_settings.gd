extends SceneTree
## The settings menu in the real title scene, with input through the real Input singleton: it fits,
## bindings change what reaches the sim and survive a restart, and no setting is ever lost.
##   godot --headless --path . -s tests/test_settings.gd

# Tests see a screen scale of 1, so the smaller sizes stand in for phones measured in dp.
const SIZES: Array[Vector2i] = [Vector2i(1280, 720), Vector2i(412, 915), Vector2i(915, 412), Vector2i(320, 568)]
const TAP_HEIGHT := 48.0
const SAVED := "user://test_settings.cfg"

var _failed := 0
var _config: Node
var _controls: Node
var _scenes: Node


func _initialize() -> void:
	# Autoloads aren't ready until the first frame.
	await process_frame
	_config = root.get_node("Config")
	_controls = root.get_node("Controls")
	_scenes = root.get_node("Scenes")
	_test_tests_leave_the_players_settings_alone()
	for touch: bool in [false, true]:
		_controls.touch_first = touch
		for size: Vector2i in SIZES:
			await _test_fits(size, touch)
	_controls.touch_first = false
	root.size = Vector2i(1280, 720)
	await _test_opens_and_closes()
	await _test_android_back()
	await _test_rebind_key()
	await _test_key_moves_between_actions()
	await _test_escape_cancels_and_delete_clears()
	await _test_rebind_pad_button_and_stick()
	_test_any_pad_plays()
	_test_stick_deadzone()
	_test_menu_buttons_on_a_pad()
	_test_hint_follows_bindings()
	await _test_settings_survive_a_restart()
	_test_audio_buses()
	print("PASS" if _failed == 0 else "FAIL (%d)" % _failed)
	quit(0 if _failed == 0 else 1)


func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_failed += 1


func _open_title() -> Control:
	var title: Control = load("res://scenes/title.tscn").instantiate()
	root.add_child(title)
	await _settle()
	return title


func _settle() -> void:
	await process_frame
	await process_frame


func _open_menu(title: Control) -> Control:
	title._settings.pressed.emit()
	await _settle()
	return title.get_child(-1)


func _close(title: Control) -> void:
	title.free()
	root.content_scale_factor = 1.0
	_controls.reset_bindings("keys")
	_controls.reset_bindings("pad")
	_controls.reset_touch()


## Through Input as the OS would, so _input and InputMap both see it.
func _key(code: Key, pressed := true) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code # Godot's own menu actions go by this
	ev.pressed = pressed
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _tap(code: Key) -> void:
	_key(code)
	_key(code, false)


func _pad_button(button: JoyButton, pressed := true, device := 0) -> void:
	var ev := InputEventJoypadButton.new()
	ev.button_index = button
	ev.pressed = pressed
	ev.device = device
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _stick(axis: JoyAxis, value: float, device := 0) -> void:
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = value
	ev.device = device
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _bit(action: String) -> int:
	return _controls.BINDINGS[action].bit


func _sends(bit: int) -> bool:
	var first: bool = _controls.sample() & bit != 0
	_controls.sample() # let any press finish before the next look
	return first


func _test_tests_leave_the_players_settings_alone() -> void:
	_check(_config.path == "", "a test doesn't read or write the player's settings file")
	_check(_controls.bindings("keys", "swap") == _controls.BINDINGS.swap.keys, "and starts from the default bindings")


func _test_fits(window_size: Vector2i, touch: bool) -> void:
	root.size = window_size
	var title := await _open_title()
	var menu := await _open_menu(title)
	var view := root.get_visible_rect()
	var what := "%s touch=%s" % [window_size, touch]
	_check(not title._menu.visible, "the title is out of the way: " + what)
	for tab: Button in menu._tabs.get_children():
		tab.pressed.emit()
		await _settle()
		var page: Control
		for child: Control in menu._pages.get_children():
			if child.visible:
				page = child
		var name := "%s, %s" % [tab.text, what]
		_check(page != null and page.size.x > 0.0, "%s page shows" % name)
		_check(tab.get_global_rect().end.x <= view.end.x and menu._column.get_global_rect().end.x <= view.end.x + 0.5,
				"%s fits across" % name)
		_check(page.get_global_rect().end.x <= view.end.x + 0.5, "%s page fits across: %s" % [name, page.get_global_rect()])
		if touch:
			for c: Control in page.find_children("*", "BaseButton", true, false):
				if c.is_visible_in_tree():
					_check(c.size.y >= TAP_HEIGHT, "%s %s is tappable" % [name, c.get_class()])
	_close(title)


func _test_opens_and_closes() -> void:
	var title := await _open_title()
	var menu := await _open_menu(title)
	_check(title.get_viewport().gui_get_focus_owner() is Button, "keys and pads have a place to start from")
	_tap(KEY_ESCAPE)
	await _settle()
	_check(title._menu.visible and not is_instance_valid(menu), "esc returns to the title")
	_check(title.get_viewport().gui_get_focus_owner() == title._settings, "with focus back on Settings")
	_close(title)


func _test_android_back() -> void:
	var title := await _open_title()
	var menu := await _open_menu(title)
	root.go_back_requested.emit()
	await process_frame
	root.go_back_requested.emit() # one press arrives twice; a second handler would quit the app
	await _settle()
	_check(title._menu.visible and not is_instance_valid(menu), "Android's back closes the menu, not the app")
	_check(_scenes.back_pressed.get_connections().is_empty(), "and on the title back quits again")
	await create_timer(_scenes.SAME_BACK_PRESS_MS / 1000.0).timeout
	menu = await _open_menu(title)
	menu._slots["keys/swap/0"].pressed.emit()
	root.go_back_requested.emit()
	await _settle()
	_check(is_instance_valid(menu) and menu._capture.is_empty(), "while binding, back only cancels that")
	_close(title)
	await process_frame


func _test_rebind_key() -> void:
	var title := await _open_title()
	var menu := await _open_menu(title)
	var slot: Button = menu._slots["keys/swap/0"]
	_check(slot.text == "Space", "the slot shows its key: %s" % slot.text)
	slot.pressed.emit()
	_check(menu._prompt.visible, "picking a slot asks for a key")
	_key(KEY_J)
	_key(KEY_J, false)
	_check(not menu._prompt.visible, "and pressing one ends that")
	_check(slot.text == "J", "the slot shows the new key: %s" % slot.text)
	_controls.reset_touch()
	_tap(KEY_J)
	_check(_sends(_bit("swap")), "the new key swaps")
	_tap(KEY_SPACE)
	_check(not _sends(_bit("swap")), "the old one doesn't")
	_tap(KEY_X)
	_check(_sends(_bit("swap")), "and the other slots still do")
	menu._reset("keys")
	_check(slot.text == "Space", "reset brings the default back: %s" % slot.text)
	_tap(KEY_SPACE)
	_check(_sends(_bit("swap")), "and it swaps again")
	_close(title)


func _test_key_moves_between_actions() -> void:
	var title := await _open_title()
	var menu := await _open_menu(title)
	menu._slots["keys/swap/0"].pressed.emit()
	_tap(KEY_C) # was raise
	_check(_controls.bindings("keys", "raise") == [KEY_L, KEY_SHIFT], "a key taken by another action leaves its old one")
	_controls.reset_touch()
	_tap(KEY_C)
	var mask: int = _controls.sample()
	_check(mask & _bit("swap") != 0 and mask & _bit("raise") == 0, "and does only its new job")
	menu._slots["keys/swap/1"].pressed.emit()
	_tap(KEY_C) # already swap, in slot 0
	_check(_controls.bindings("keys", "swap") == [KEY_C, KEY_X, KEY_K], "binding a key twice on one action changes nothing")
	for key: Key in [KEY_DOWN, KEY_S]:
		menu._slots["keys/up/0"].pressed.emit()
		_tap(key)
	_check(_controls.bindings("keys", "down").is_empty(), "taking all of an action's keys leaves it with none")
	menu._refresh_bindings()
	_check(menu._warnings.keys.visible and "Down" in menu._warnings.keys.text, "and the page says so")
	_close(title)


func _test_escape_cancels_and_delete_clears() -> void:
	var title := await _open_title()
	var menu := await _open_menu(title)
	menu._slots["keys/swap/0"].pressed.emit()
	_tap(KEY_ESCAPE)
	await _settle()
	_check(is_instance_valid(menu) and not menu._prompt.visible, "esc cancels the binding without closing the menu")
	_check(_controls.bindings("keys", "swap")[0] == KEY_SPACE, "and changes nothing")
	menu._slots["keys/swap/0"].pressed.emit()
	_tap(KEY_DELETE)
	_check(_controls.bindings("keys", "swap") == [KEY_X, KEY_K], "delete clears the slot")
	_check(not menu._prompt.visible, "and ends the binding")
	_close(title)


func _test_rebind_pad_button_and_stick() -> void:
	var title := await _open_title()
	var menu := await _open_menu(title)
	menu._slots["pad/swap/0"].pressed.emit()
	_tap(KEY_J)
	_check(menu._prompt.visible, "a key doesn't bind on the gamepad page")
	_pad_button(JOY_BUTTON_START)
	_pad_button(JOY_BUTTON_START, false)
	_check(not menu._prompt.visible and _controls.bindings("pad", "swap")[0] == JOY_BUTTON_A, "start cancels")
	menu._slots["pad/swap/0"].pressed.emit()
	_pad_button(JOY_BUTTON_Y)
	_pad_button(JOY_BUTTON_Y, false)
	_check(_controls.bindings("pad", "swap")[0] == JOY_BUTTON_Y, "a button binds")
	_check(menu._slots["pad/swap/0"].text == "Y", "and shows its name: %s" % menu._slots["pad/swap/0"].text)
	_controls.reset_touch()
	_pad_button(JOY_BUTTON_Y)
	_check(_sends(_bit("swap")), "and swaps")
	_pad_button(JOY_BUTTON_Y, false)
	menu._slots["pad/raise/2"].pressed.emit()
	_stick(JOY_AXIS_RIGHT_X, 0.2)
	_check(menu._prompt.visible, "a stick resting off-centre doesn't bind")
	_stick(JOY_AXIS_RIGHT_X, -0.9)
	_check(_controls.bindings("pad", "raise")[-1] == Vector2i(JOY_AXIS_RIGHT_X, -1), "a stick pushed one way binds that way")
	_check(menu._slots["pad/raise/2"].text == "RS Left", "and shows its name: %s" % menu._slots["pad/raise/2"].text)
	_stick(JOY_AXIS_RIGHT_X, 0.0)
	menu._slots["pad/raise/2"].pressed.emit()
	_pad_button(JOY_BUTTON_BACK)
	_pad_button(JOY_BUTTON_BACK, false)
	_check(_controls.bindings("pad", "raise").size() == 2, "back clears the slot")
	_close(title)


func _test_any_pad_plays() -> void:
	_controls.reset_touch()
	_pad_button(JOY_BUTTON_A, true, 3)
	_check(_sends(_bit("swap")), "a pad that isn't device 0 plays")
	_pad_button(JOY_BUTTON_A, false, 3)
	_controls.sample()


func _test_stick_deadzone() -> void:
	_controls.reset_touch()
	_stick(JOY_AXIS_LEFT_X, -0.3)
	_check(not _sends(_bit("left")), "a small push stays in the deadzone")
	_stick(JOY_AXIS_LEFT_X, -0.8)
	_check(_sends(_bit("left")), "a real push moves left")
	_stick(JOY_AXIS_LEFT_X, 0.0)
	_controls.sample()
	_config.set_value("controls", "stick_deadzone", 0.2)
	_controls.apply_bindings()
	_stick(JOY_AXIS_LEFT_X, -0.3)
	_check(_sends(_bit("left")), "a smaller deadzone lets the small push through")
	_stick(JOY_AXIS_LEFT_X, 0.0)
	_controls.sample()
	_config.set_value("controls", "stick_deadzone", _config.DEFAULTS.controls.stick_deadzone)
	_controls.apply_bindings()


func _test_menu_buttons_on_a_pad() -> void:
	var accept := InputEventJoypadButton.new()
	accept.button_index = JOY_BUTTON_A
	accept.device = 2
	accept.pressed = true
	var cancel := InputEventJoypadButton.new()
	cancel.button_index = JOY_BUTTON_B
	cancel.device = 2
	cancel.pressed = true
	var start := InputEventJoypadButton.new()
	start.button_index = JOY_BUTTON_START
	start.device = 2
	start.pressed = true
	_check(accept.is_action("ui_accept"), "A picks in menus")
	_check(cancel.is_action("ui_cancel"), "B goes back in menus")
	_check(not cancel.is_action("leave"), "B, which also swaps, can't leave a match")
	_check(start.is_action("leave"), "start can")


func _test_hint_follows_bindings() -> void:
	var hint: String = _controls.hint()
	_check(hint.begins_with("arrows/WASD move · Space/X swap · C/L raise"), "the hint says the defaults: " + hint)
	_controls.bind("keys", "swap", 0, KEY_J)
	_controls.unbind("keys", "up", 1)
	hint = _controls.hint()
	_check(hint.begins_with("arrows move · J/X swap"), "and what they've become: " + hint)
	_controls.reset_bindings("keys")


func _test_settings_survive_a_restart() -> void:
	DirAccess.remove_absolute(SAVED)
	_config.path = SAVED
	_controls.bind("keys", "swap", 0, KEY_J)
	_controls.bind("pad", "raise", 0, Vector2i(JOY_AXIS_TRIGGER_RIGHT, 1))
	_config.set_value("video", "renderer", "2d")
	var loaded := ConfigFile.new()
	_check(loaded.load(SAVED) == OK, "changes are saved as they happen")
	_config._cfg = loaded
	_controls.apply_bindings()
	_check(_controls.bindings("keys", "swap") == [KEY_J, KEY_X, KEY_K], "keys come back")
	_check(_controls.bindings("pad", "raise")[0] == Vector2i(JOY_AXIS_TRIGGER_RIGHT, 1), "stick and trigger bindings come back")
	_check(_config.get_value("video", "renderer") == "2d", "other settings come back")
	_tap(KEY_J)
	_check(_sends(_bit("swap")), "and the restored key plays")
	_config._cfg = ConfigFile.new()
	_config.path = ""
	_controls.apply_bindings()
	DirAccess.remove_absolute(SAVED)


func _test_audio_buses() -> void:
	for bus: String in ["Master", "Music", "SFX"]:
		_check(AudioServer.get_bus_index(bus) != -1, "%s bus exists for sounds to play on" % bus)
	_config.set_value("audio", "sfx", 0.5)
	_config.apply()
	var bus := AudioServer.get_bus_index("SFX")
	_check(is_equal_approx(AudioServer.get_bus_volume_linear(bus), 0.5), "the effects slider sets the bus")
	_config.set_value("audio", "sfx", 1.0)
	_config.apply()
