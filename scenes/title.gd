extends Control
## Title + lobby. UI is built in code so there's no fragile .tscn layout yet.
## Laid out in density-independent pixels: see _fit_to_screen.

const COLUMN_WIDTH := 360.0
const SettingsMenu := preload("res://scenes/settings_menu.gd")
const GAP := 10
const TWO_COLUMNS_BELOW := 640.0 # one column of tap-sized rows doesn't fit a landscape phone

var _status: Label
var _name: LineEdit
var _address: LineEdit
var _room: LineEdit
var _quick: Button
var _cpu: OptionButton
var _level: OptionButton
var _format: OptionButton
var _room_format: OptionButton
var _blurb: Label
var _columns: BoxContainer
var _online: VBoxContainer
var _offline: VBoxContainer
var _menu: ScrollContainer
var _play: Button
var _settings: Button
# Whether this platform gets these buttons. Set before it enters the tree, tests stand in for one.
var can_host: bool = Config.can_host()
var can_quit: bool = Config.can_quit()


func _ready() -> void:
	# And offsets too: on its own, set_anchors_preset keeps the current rect, here 0x0.
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var scroll := ScrollContainer.new() # a safety net: a tiny window can still reach everything
	scroll.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_menu = scroll
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
	# The internet, through the match server.
	_quick = _button(_online, "Quick match", _quick_match)
	var room_row := HBoxContainer.new()
	room_row.add_theme_constant_override("separation", GAP)
	_online.add_child(room_row)
	_room = _field(room_row, "Room code", "")
	_room.max_length = 16
	_room.size_flags_horizontal = SIZE_EXPAND_FILL
	_room.text_submitted.connect(func(_t: String) -> void: _play_room())
	_button(room_row, "Play a friend", _play_room).tooltip_text = "Leave the code empty to make a room and copy an invite link"
	# What a room you make is for. Whoever joins plays the room's format, whatever theirs says.
	_room_format = OptionButton.new()
	Controls.size_for_fingers(_room_format)
	_room_format.tooltip_text = "Making a room: how many play, on which teams. Joining one: its maker's choice counts"
	for f: String in Net.FORMATS:
		var seats: int = Net.FORMATS[f].size()
		_room_format.add_item("Room for %s: %s" % [f, "you and a friend" if seats == 2 else "%d players" % seats])
	_room_format.select(maxi(0, Net.FORMATS.values().find(Array(Net.room_teams))))
	_room_format.item_selected.connect(func(i: int) -> void:
		Net.room_teams = PackedInt32Array(Net.FORMATS.values()[i]) if i > 0 else PackedInt32Array())
	_room_format.clip_text = true
	_room_format.size_flags_horizontal = SIZE_EXPAND_FILL
	_online.add_child(_room_format)
	# The same room, on a LAN, without a server.
	_address = _field(_online, "LAN host address", Config.get_value("net", "address"))
	var lan_row := HBoxContainer.new()
	lan_row.add_theme_constant_override("separation", GAP)
	_online.add_child(lan_row)
	if can_host:
		_button(lan_row, "Host", _host).size_flags_horizontal = SIZE_EXPAND_FILL
	_button(lan_row, "Join", _join).size_flags_horizontal = SIZE_EXPAND_FILL
	var row := HBoxContainer.new()
	_cpu = OptionButton.new()
	_cpu.size_flags_horizontal = SIZE_EXPAND_FILL
	_cpu.clip_text = true
	Controls.size_for_fingers(_cpu)
	for n: String in CpuPlayer.OPPONENTS:
		_cpu.add_item(n)
	_cpu.add_item("Endless (solo)")
	_level = OptionButton.new()
	Controls.size_for_fingers(_level)
	for l: String in CpuPlayer.LEVELS:
		_level.add_item(l)
	_level.select(CpuPlayer.LEVELS.find(Net.cpu_level))
	if Net.cpu_name in CpuPlayer.OPPONENTS:
		_cpu.select(CpuPlayer.OPPONENTS.keys().find(Net.cpu_name))
	_format = OptionButton.new()
	Controls.size_for_fingers(_format)
	_format.tooltip_text = "Who plays: you and CPU teammates against CPU opponents"
	for f: String in Net.FORMATS:
		_format.add_item(f if f != "1v1" else "1v1: you against them")
	_format.select(maxi(0, Net.FORMATS.values().find(Array(Net.practice_teams))))
	_format.item_selected.connect(func(i: int) -> void:
		Net.practice_teams = PackedInt32Array(Net.FORMATS.values()[i]) if i > 0 else PackedInt32Array())
	row.add_child(_cpu)
	row.add_child(_level)
	_offline.add_child(row)
	_format.size_flags_horizontal = SIZE_EXPAND_FILL
	_offline.add_child(_format)
	_blurb = Label.new()
	_blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_blurb.modulate = Color(1, 1, 1, 0.6)
	_offline.add_child(_blurb)
	_cpu.item_selected.connect(_on_cpu_selected)
	_on_cpu_selected(_cpu.selected)
	_play = _button(_offline, "Play", _play_offline)
	var bottom := HBoxContainer.new() # a row, so it adds no height to a landscape phone's menu
	bottom.add_theme_constant_override("separation", GAP)
	box.add_child(bottom)
	_settings = _button(bottom, "Settings", _open_settings)
	_settings.size_flags_horizontal = SIZE_EXPAND_FILL
	if can_quit:
		_button(bottom, "Quit", get_tree().quit).size_flags_horizontal = SIZE_EXPAND_FILL

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)

	get_window().size_changed.connect(_fit_to_screen)
	_fit_to_screen()

	Net.status.connect(_on_status)
	Net.opponent_joined.connect(_on_opponent_joined)
	if Controls.navigates_by_focus():
		_play.grab_focus()

	var args := Scenes.launch_args
	Scenes.launch_args = {}
	# --format=2v2 and so on, for offline play against CPUs
	if args.has("format") and str(args.format) in Net.FORMATS:
		Net.practice_teams = PackedInt32Array(Net.FORMATS[str(args.format)]) if args.format != "1v1" else PackedInt32Array()
		_format.select(Net.FORMATS.keys().find(str(args.format)))
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


## A keyboard or pad picked up on a touch screen, where nothing started with focus.
func _unhandled_input(event: InputEvent) -> void:
	if not _menu.visible or get_viewport().gui_get_focus_owner() != null:
		return
	for action: String in ["ui_up", "ui_down", "ui_left", "ui_right", "ui_accept", "ui_focus_next"]:
		if event.is_action_pressed(action):
			_play.grab_focus()
			get_viewport().set_input_as_handled()
			return


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
	_format.disabled = i >= names.size()
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


## Over the title, not instead of it: a host waiting for an opponent is still in this lobby.
func _open_settings() -> void:
	var menu := SettingsMenu.new()
	menu.closed.connect(_on_settings_closed)
	_menu.visible = false
	add_child(menu)


func _on_settings_closed() -> void:
	_menu.visible = true
	if Controls.navigates_by_focus():
		_settings.grab_focus()


func _field(box: Container, label: String, value: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = label
	edit.text = value
	Controls.size_for_fingers(edit)
	box.add_child(edit)
	return edit


func _button(box: Container, label: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = label
	Controls.size_for_fingers(b)
	b.pressed.connect(action)
	box.add_child(b)
	return b


func _save_fields() -> void:
	Config.set_value("player", "name", _name.text)
	Config.set_value("net", "address", _address.text)


func _quick_match() -> void:
	_save_fields()
	Net.play_online()


## A code joins that room. No code makes one, and copies a link that opens the web game in it.
func _play_room() -> void:
	_save_fields()
	var code := ""
	for c in _room.text.strip_edges().to_upper():
		if (c >= "A" and c <= "Z") or (c >= "0" and c <= "9"):
			code += c
	if code == "":
		code = Net.new_room_code()
		var link := Net.invite_link(code)
		if link != "":
			DisplayServer.clipboard_set(link)
	_room.text = code
	Net.play_online(code, null, Net.room_teams)


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
