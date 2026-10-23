extends Control
## Title + lobby. UI is built in code so there's no fragile .tscn layout yet.

var _status: Label
var _name: LineEdit
var _address: LineEdit
var _cpu: OptionButton
var _level: OptionButton
var _blurb: Label


func _ready() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	var center := CenterContainer.new()
	center.set_anchors_preset(PRESET_FULL_RECT)
	add_child(center)
	var box := VBoxContainer.new()
	box.custom_minimum_size.x = 360
	box.add_theme_constant_override("separation", 10)
	center.add_child(box)

	var title := Label.new()
	title.text = ProjectSettings.get_setting("application/config/name")
	title.add_theme_font_size_override("font_size", 28)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	_name = _field(box, "Name", Config.get_value("player", "name"))
	_address = _field(box, "Host address", Config.get_value("net", "address"))
	_button(box, "Host", _host)
	_button(box, "Join", _join)
	box.add_child(HSeparator.new())
	var row := HBoxContainer.new()
	_cpu = OptionButton.new()
	_cpu.size_flags_horizontal = SIZE_EXPAND_FILL
	for n: String in CpuPlayer.OPPONENTS:
		_cpu.add_item(n)
	_cpu.add_item("Endless (solo)")
	_level = OptionButton.new()
	for l: String in CpuPlayer.LEVELS:
		_level.add_item(l)
	_level.select(CpuPlayer.LEVELS.find(Net.cpu_level))
	if Net.cpu_name in CpuPlayer.OPPONENTS:
		_cpu.select(CpuPlayer.OPPONENTS.keys().find(Net.cpu_name))
	row.add_child(_cpu)
	row.add_child(_level)
	box.add_child(row)
	_blurb = Label.new()
	_blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_blurb.modulate = Color(1, 1, 1, 0.6)
	box.add_child(_blurb)
	_cpu.item_selected.connect(_on_cpu_selected)
	_on_cpu_selected(_cpu.selected)
	_button(box, "Play", _play_offline)
	box.add_child(HSeparator.new())
	if not OS.has_feature("web"):
		_button(box, "Quit", get_tree().quit)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(_status)

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


func _on_cpu_selected(i: int) -> void:
	var names: Array = CpuPlayer.OPPONENTS.keys()
	_level.disabled = i >= names.size()
	_blurb.text = CpuPlayer.OPPONENTS[names[i]].blurb if i < names.size() else "Just you and the stack."


func _play_offline() -> void:
	var names: Array = CpuPlayer.OPPONENTS.keys()
	Net.demo = false
	Net.start_practice(names[_cpu.selected] if _cpu.selected < names.size() else "",
			CpuPlayer.LEVELS[_level.selected])


func _field(box: Container, label: String, value: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = label
	edit.text = value
	box.add_child(edit)
	return edit


func _button(box: Container, label: String, action: Callable) -> void:
	var b := Button.new()
	b.text = label
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
