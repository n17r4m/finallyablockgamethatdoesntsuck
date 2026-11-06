extends Control
## Title + lobby. UI is built in code so there's no fragile .tscn layout yet.
## Laid out in density-independent pixels: see _fit_to_screen.

const COLUMN_WIDTH := 360.0
const TAP_HEIGHT := 48.0 # the usual minimum for a finger, on touch screens
const POPUP_ROW_GAP := 21 # makes dropdown rows about 44 tall, so all six fit on a landscape phone
const GAP := 10
const TWO_COLUMNS_BELOW := 640.0 # one column of tap-sized rows doesn't fit a landscape phone

var _status: Label
var _name: LineEdit
var _address: LineEdit
var _cpu: OptionButton
var _level: OptionButton
var _blurb: Label
var _columns: BoxContainer
var _online: VBoxContainer
var _offline: VBoxContainer


func _ready() -> void:
	# And offsets too: on its own, set_anchors_preset keeps the current rect, here 0x0.
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var scroll := ScrollContainer.new() # a safety net: a tiny window can still reach everything
	scroll.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var center := CenterContainer.new()
	center.size_flags_horizontal = SIZE_EXPAND_FILL
	center.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", GAP)
	center.add_child(box)

	var title := Label.new()
	title.text = ProjectSettings.get_setting("application/config/name")
	title.add_theme_font_size_override("font_size", 28)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(title)

	_columns = BoxContainer.new()
	_columns.add_theme_constant_override("separation", 3 * GAP)
	box.add_child(_columns)
	_online = _column()
	_offline = _column()

	_name = _field(_online, "Name", Config.get_value("player", "name"))
	_address = _field(_online, "Host address", Config.get_value("net", "address"))
	_button(_online, "Host", _host)
	_button(_online, "Join", _join)
	var row := HBoxContainer.new()
	_cpu = OptionButton.new()
	_cpu.size_flags_horizontal = SIZE_EXPAND_FILL
	_cpu.clip_text = true
	_tappable(_cpu)
	for n: String in CpuPlayer.OPPONENTS:
		_cpu.add_item(n)
	_cpu.add_item("Endless (solo)")
	_level = OptionButton.new()
	_tappable(_level)
	for l: String in CpuPlayer.LEVELS:
		_level.add_item(l)
	_level.select(CpuPlayer.LEVELS.find(Net.cpu_level))
	if Net.cpu_name in CpuPlayer.OPPONENTS:
		_cpu.select(CpuPlayer.OPPONENTS.keys().find(Net.cpu_name))
	row.add_child(_cpu)
	row.add_child(_level)
	_offline.add_child(row)
	_blurb = Label.new()
	_blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_blurb.modulate = Color(1, 1, 1, 0.6)
	_offline.add_child(_blurb)
	_cpu.item_selected.connect(_on_cpu_selected)
	_on_cpu_selected(_cpu.selected)
	_button(_offline, "Play", _play_offline)
	if not OS.has_feature("web"):
		_button(box, "Quit", get_tree().quit)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)

	get_window().size_changed.connect(_fit_to_screen)
	_fit_to_screen()

	Net.status.connect(_on_status)
	Net.opponent_joined.connect(_on_opponent_joined)

	var args := Scenes.launch_args
	Scenes.launch_args = {}
	if args.has("host"):
		_host()
	elif args.has("join"):
		if args.join is String:
			_address.text = args.join
		_join()
	elif args.has("practice"):
		Net.start_practice("")
	elif args.has("cpu") or args.has("demo"):
		# --cpu=Name[:level], --demo[=Name[:level]] (the CPU plays your board too)
		var spec: String = str(args.get("cpu", args.get("demo")))
		var parts := spec.split(":")
		var name := parts[0] if parts[0] in CpuPlayer.OPPONENTS else "Overmind"
		Net.demo = args.has("demo")
		Net.start_practice(name, parts[1] if parts.size() > 1 and parts[1] in CpuPlayer.LEVELS else "hard")


func _exit_tree() -> void:
	# First, or the size change this causes would call _fit_to_screen and undo it.
	get_window().size_changed.disconnect(_fit_to_screen)
	get_window().content_scale_factor = 1.0 # the match draws in project units


## The project stretches 1280x720 to fit, which on a phone shrinks a 360-wide menu to a sliver.
## Undoing that here means one unit is one dp on any screen; big screens still zoom as before.
func _fit_to_screen() -> void:
	get_window().content_scale_factor = Controls.dp_scale()
	var view := get_viewport_rect().size
	var margin := 2.0 * GAP
	var stacked := view.y >= TWO_COLUMNS_BELOW or view.y > view.x
	_columns.vertical = stacked
	var width := minf(COLUMN_WIDTH, view.x - 2.0 * margin if stacked else (view.x - 2.0 * margin - 3.0 * GAP) / 2.0)
	_online.custom_minimum_size.x = width
	_offline.custom_minimum_size.x = width


func _on_cpu_selected(i: int) -> void:
	var names: Array = CpuPlayer.OPPONENTS.keys()
	_level.disabled = i >= names.size()
	_blurb.text = CpuPlayer.OPPONENTS[names[i]].blurb if i < names.size() else "Just you and the stack."


func _play_offline() -> void:
	var names: Array = CpuPlayer.OPPONENTS.keys()
	Net.demo = false
	Net.start_practice(names[_cpu.selected] if _cpu.selected < names.size() else "",
			CpuPlayer.LEVELS[_level.selected])


func _column() -> VBoxContainer:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", GAP)
	_columns.add_child(column)
	return column


func _tappable(control: Control) -> void:
	if Controls.touch_first:
		control.custom_minimum_size.y = TAP_HEIGHT
		if control is OptionButton:
			control.get_popup().add_theme_constant_override("v_separation", POPUP_ROW_GAP)


func _field(box: Container, label: String, value: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = label
	edit.text = value
	_tappable(edit)
	box.add_child(edit)
	return edit


func _button(box: Container, label: String, action: Callable) -> void:
	var b := Button.new()
	b.text = label
	_tappable(b)
	b.pressed.connect(action)
	box.add_child(b)


func _save_fields() -> void:
	Config.set_value("player", "name", _name.text)
	Config.set_value("net", "address", _address.text)


func _host() -> void:
	_save_fields()
	Net.host(Config.get_value("net", "port"))


func _join() -> void:
	_save_fields()
	Net.join(_address.text.strip_edges(), Config.get_value("net", "port"))


func _on_status(text: String) -> void:
	_status.text = text


func _on_opponent_joined() -> void:
	if Net.hosting:
		Net.start_match()
