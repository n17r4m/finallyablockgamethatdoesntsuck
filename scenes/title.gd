extends Control
## Title + lobby. UI is built in code so there's no fragile .tscn layout yet.

var _status: Label
var _name: LineEdit
var _address: LineEdit


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
	_button(box, "Practice", Net.start_practice)
	if not OS.has_feature("web"):
		_button(box, "Quit", get_tree().quit)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(_status)

	Net.status.connect(_on_status)
	Net.opponent_joined.connect(_on_opponent_joined)
	Net.match_started.connect(_on_match_started)

	var args := Scenes.launch_args
	Scenes.launch_args = {}
	if args.has("host"):
		_host()
	elif args.has("join"):
		if args.join is String:
			_address.text = args.join
		_join()
	elif args.has("practice"):
		Net.start_practice()


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


func _on_match_started() -> void:
	Scenes.goto(Scenes.MATCH)
