extends Control
## Settings, over the title. Built in code like the title, in the same dp units. Every change
## applies and saves at once, so there's nothing to confirm and nothing to lose.
##
## None of this reaches the sim: bindings only change which key makes which bit of the input.

signal closed

const WIDTH := 540.0
const MARGIN := 16.0
const GAP := 10
const LABEL_WIDTH := 90.0
const NOTE_ALPHA := 0.6
const WARNING := Color(1.0, 0.7, 0.3)
const TAB_CHOSEN := Color(0.25, 0.32, 0.5)
const FPS_LIMITS := {"Off": 0, "60": 60, "120": 120, "144": 144, "240": 240}
const RENDERERS := {"3D": "3d", "2D (low detail)": "2d"}
const DEVICE_WORDS := {"keys": "key", "pad": "button or stick"}

var _column: VBoxContainer
var _tabs: HFlowContainer
var _pages: VBoxContainer
var _tab_group := ButtonGroup.new()
var _slots := {} # "device/action/slot" -> Button
var _warnings := {} # device -> Label
var _pad_status: Label
var _capture := {} # {device, action, slot} while waiting for a key or button
var _prompt: Control
var _prompt_text: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var backdrop := ColorRect.new()
	backdrop.color = RenderingServer.get_default_clear_color()
	backdrop.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(backdrop)
	_column = VBoxContainer.new()
	_column.add_theme_constant_override("separation", GAP)
	_column.set_anchors_preset(PRESET_FULL_RECT)
	add_child(_column)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", GAP)
	_column.add_child(header)
	var back := _button("Back", close)
	back.custom_minimum_size.x = 72.0
	header.add_child(back)
	var title := Label.new()
	title.text = "Settings"
	title.add_theme_font_size_override("font_size", 22)
	header.add_child(title)

	_tabs = HFlowContainer.new()
	_tabs.add_theme_constant_override("h_separation", GAP / 2)
	_tabs.add_theme_constant_override("v_separation", GAP / 2)
	_column.add_child(_tabs)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	_column.add_child(scroll)
	_pages = VBoxContainer.new()
	_pages.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(_pages)

	var first := _add_page("Display", _build_display)
	_add_page("Sound", _build_sound)
	# The same gestures either way, so name what this player has.
	if Controls.touch_first:
		_add_page("Touch", _build_touch)
	_add_page("Keyboard", _build_binding_page.bind("keys"))
	_add_page("Gamepad", _build_binding_page.bind("pad"))
	if not Controls.touch_first:
		_add_page("Mouse", _build_touch)
	_refresh_bindings()
	_show_page(first, _pages.get_child(0))

	_build_prompt()
	resized.connect(_fit)
	_fit()
	Scenes.back_pressed.connect(_on_back)
	Input.joy_connection_changed.connect(_on_pad_changed)
	if Controls.navigates_by_focus():
		first.grab_focus()


func close() -> void:
	closed.emit()
	queue_free()


## Android's back: one level at a time, then to the title.
func _on_back() -> void:
	if _capture.is_empty():
		close()
	else:
		_end_capture()


func _fit() -> void:
	var side := maxf(MARGIN, (size.x - WIDTH) / 2.0)
	_column.offset_left = side
	_column.offset_right = -side
	_column.offset_top = MARGIN
	_column.offset_bottom = -MARGIN


## Claims every key and button while binding, before the focused button or a menu can see them.
func _input(event: InputEvent) -> void:
	if _capture.is_empty():
		if event.is_action_pressed("ui_cancel"):
			get_viewport().set_input_as_handled()
			close()
		return
	if not (event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion):
		return
	get_viewport().set_input_as_handled()
	if event.is_action_pressed("leave"):
		_end_capture()
	elif event is InputEventKey and event.pressed and event.physical_keycode == KEY_DELETE:
		_clear_capture()
	elif event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_BACK:
		_clear_capture()
	else:
		var code: Variant = Controls.binding_code(event, _capture.device)
		if code != null:
			Controls.bind(_capture.device, _capture.action, _capture.slot, code)
			_end_capture()


func _add_page(label: String, build: Callable) -> Button:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", GAP)
	page.size_flags_horizontal = SIZE_EXPAND_FILL
	page.visible = false
	_pages.add_child(page)
	build.call(page)
	var tab := _button(label, Callable())
	tab.toggle_mode = true
	tab.button_group = _tab_group
	tab.custom_minimum_size.x = 76.0
	var chosen := StyleBoxFlat.new() # the theme's pressed look is barely different from its normal one
	chosen.bg_color = TAB_CHOSEN
	chosen.set_corner_radius_all(3)
	chosen.set_content_margin_all(4.0)
	tab.add_theme_stylebox_override("pressed", chosen)
	tab.add_theme_stylebox_override("hover_pressed", chosen)
	tab.pressed.connect(_show_page.bind(tab, page))
	_tabs.add_child(tab)
	return tab


func _show_page(tab: Button, page: Control) -> void:
	for other: Control in _pages.get_children():
		other.visible = other == page
	tab.button_pressed = true


func _build_display(page: Control) -> void:
	if Config.can_set_fullscreen():
		_check(page, "Fullscreen", Config.is_fullscreen(), Config.set_fullscreen)
	if Config.can_set_vsync():
		_check(page, "VSync", Config.get_value("video", "vsync"), _set_and_apply.bind("video", "vsync"))
	if Config.can_limit_fps():
		_options(page, "Frame limit", FPS_LIMITS, Config.get_value("video", "max_fps"), _set_and_apply.bind("video", "max_fps"))
	_options(page, "Graphics", RENDERERS, Config.get_value("video", "renderer"), _set_and_apply.bind("video", "renderer"))
	_check(page, "Show match stats", Config.get_value("video", "show_stats"), _set_and_apply.bind("video", "show_stats"))


func _build_sound(page: Control) -> void:
	_note(page, "The game has no sounds yet. These will apply as soon as it does.")
	for row: Array in [["Master", "master"], ["Music", "music"], ["Effects", "sfx"]]:
		_slider(page, row[0], Config.get_value("audio", row[1]), 0.0, 1.0, 0.05,
				func(v: float) -> String: return "%d%%" % roundi(v * 100.0),
				_set_and_apply.bind("audio", row[1]))


func _build_touch(page: Control) -> void:
	_note(page, "Drag a block to carry it, flick it to swap once, tap to move the cursor, and hold the rising row to raise.")
	_slider(page, "Pick-up delay", Controls.carry_delay_ms, 50.0, 250.0, 10.0,
			func(v: float) -> String: return "%d ms" % int(v), _set_carry_delay)
	_note(page, "How long to rest on a block before moving it counts as a carry. Shorter picks blocks up sooner; longer leaves more time to flick. Default: %d ms." % Config.DEFAULTS.controls.carry_delay_ms)


func _build_binding_page(page: Control, device: String) -> void:
	if device == "pad":
		_pad_status = _note(page, "")
		_on_pad_changed(0, false)
	else:
		_note(page, "Pick a slot, then press the key to put there. Esc and Delete can't be bound.")
	var grid := GridContainer.new()
	grid.columns = 1 + Controls.SLOTS
	grid.add_theme_constant_override("h_separation", GAP / 2)
	grid.add_theme_constant_override("v_separation", GAP / 2)
	page.add_child(grid)
	for action: String in Controls.BINDINGS:
		var label := Label.new()
		label.text = Controls.BINDINGS[action].label
		label.custom_minimum_size.x = 60.0
		grid.add_child(label)
		for slot in Controls.SLOTS:
			var b := _button("", _start_capture.bind(device, action, slot))
			b.size_flags_horizontal = SIZE_EXPAND_FILL
			b.clip_text = true
			b.custom_minimum_size.x = 66.0
			grid.add_child(b)
			_slots["%s/%s/%d" % [device, action, slot]] = b
	var warning := Label.new()
	warning.add_theme_color_override("font_color", WARNING)
	warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(warning)
	_warnings[device] = warning
	page.add_child(_button("Reset to defaults", _reset.bind(device)))
	if device == "pad":
		_slider(page, "Stick deadzone", Config.get_value("controls", "stick_deadzone"), 0.1, 0.9, 0.05,
				func(v: float) -> String: return "%d%%" % roundi(v * 100.0), _set_deadzone)


func _refresh_bindings() -> void:
	for device: String in _warnings:
		var missing := PackedStringArray()
		for action: String in Controls.BINDINGS:
			var list := Controls.bindings(device, action)
			if list.is_empty():
				missing.append(Controls.BINDINGS[action].label)
			for slot in Controls.SLOTS:
				_slots["%s/%s/%d" % [device, action, slot]].text = (
						Controls.binding_name(device, list[slot]) if slot < list.size() else "—")
		_warnings[device].text = "" if missing.is_empty() else "Nothing does: %s" % ", ".join(missing)
		_warnings[device].visible = not missing.is_empty()


func _reset(device: String) -> void:
	Controls.reset_bindings(device)
	_refresh_bindings()


func _set_and_apply(value: Variant, section: String, key: String) -> void:
	Config.set_value(section, key, value)
	Config.apply()


func _set_carry_delay(ms: float) -> void:
	Config.set_value("controls", "carry_delay_ms", int(ms))
	Controls.carry_delay_ms = int(ms)


func _set_deadzone(amount: float) -> void:
	Config.set_value("controls", "stick_deadzone", amount)
	Controls.apply_bindings()


func _on_pad_changed(_device: int, _connected: bool) -> void:
	var pads := Input.get_connected_joypads()
	_pad_status.text = ("Pick a slot, then press the button or move the stick to put there. Start and Back can't be bound.\nConnected: %s" % Input.get_joy_name(pads[0])
			if not pads.is_empty() else "No gamepad connected. Plug one in to set it up.")


func _start_capture(device: String, action: String, slot: int) -> void:
	_capture = {"device": device, "action": action, "slot": slot}
	var cancel := "Esc cancels, Delete clears the slot." if device == "keys" else "Start cancels, Back clears the slot."
	_prompt_text.text = "Press a %s for %s\n%s" % [DEVICE_WORDS[device], Controls.BINDINGS[action].label, cancel]
	_prompt.visible = true


func _end_capture() -> void:
	_capture = {}
	_prompt.visible = false
	_refresh_bindings()


func _clear_capture() -> void:
	Controls.unbind(_capture.device, _capture.action, _capture.slot)
	_end_capture()


func _build_prompt() -> void:
	_prompt = ColorRect.new()
	_prompt.color = Color(0, 0, 0, 0.75)
	_prompt.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_prompt.visible = false
	add_child(_prompt)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_prompt.add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var margin := MarginContainer.new()
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 2 * GAP)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", GAP)
	margin.add_child(box)
	_prompt_text = Label.new()
	_prompt_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_prompt_text)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", GAP)
	box.add_child(row)
	# No focus, or the key being bound could press them.
	for pair: Array in [["Clear slot", _clear_capture], ["Cancel", _end_capture]]:
		var b := _button(pair[0], pair[1])
		b.focus_mode = FOCUS_NONE
		b.size_flags_horizontal = SIZE_EXPAND_FILL
		row.add_child(b)


func _button(label: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = label
	Controls.size_for_fingers(b)
	if action.is_valid():
		b.pressed.connect(action)
	return b


func _row(page: Control, label: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", GAP)
	var text := Label.new()
	text.text = label
	text.custom_minimum_size.x = LABEL_WIDTH
	text.size_flags_horizontal = SIZE_EXPAND_FILL
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(text)
	page.add_child(row)
	return row


func _check(page: Control, label: String, on: bool, changed: Callable) -> void:
	var toggle := CheckButton.new()
	toggle.button_pressed = on
	Controls.size_for_fingers(toggle)
	toggle.toggled.connect(changed)
	_row(page, label).add_child(toggle)


## choices: shown text -> value.
func _options(page: Control, label: String, choices: Dictionary, current: Variant, changed: Callable) -> void:
	var menu := OptionButton.new()
	for text: String in choices:
		menu.add_item(text)
	menu.select(maxi(0, choices.values().find(current)))
	menu.custom_minimum_size.x = 170.0
	Controls.size_for_fingers(menu)
	menu.item_selected.connect(func(i: int) -> void: changed.call(choices.values()[i]))
	_row(page, label).add_child(menu)


func _slider(page: Control, label: String, value: float, lo: float, hi: float, step: float,
		show: Callable, changed: Callable) -> void:
	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	slider.value = value
	slider.custom_minimum_size = Vector2(100.0, 24.0)
	slider.size_flags_vertical = SIZE_SHRINK_CENTER
	Controls.size_for_fingers(slider)
	var readout := Label.new()
	readout.text = show.call(value)
	readout.custom_minimum_size.x = 50.0
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	slider.value_changed.connect(func(v: float) -> void:
		readout.text = show.call(v)
		changed.call(v))
	var row := _row(page, label)
	row.add_child(slider)
	row.add_child(readout)


func _note(page: Control, text: String) -> Label:
	var note := Label.new()
	note.text = text
	note.modulate.a = NOTE_ALPHA
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(note)
	return note
