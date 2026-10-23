extends Node
## Persistent settings in user://settings.cfg. Autoload #1: everything after reads from here.

const PATH := "user://settings.cfg"
const DEFAULTS := {
	"player": {"name": "Player"},
	"net": {"address": "127.0.0.1", "port": 47100, "transport": "enet", "input_delay_frames": 2},
	"video": {"fullscreen": false, "vsync": true},
}

var _cfg := ConfigFile.new()


func _ready() -> void:
	_cfg.load(PATH) # missing file is fine; defaults fill in
	apply()


func get_value(section: String, key: String) -> Variant:
	return _cfg.get_value(section, key, DEFAULTS[section][key])


func set_value(section: String, key: String, value: Variant) -> void:
	_cfg.set_value(section, key, value)
	_cfg.save(PATH)


func apply() -> void:
	if OS.has_feature("web") or OS.has_feature("mobile"):
		return
	DisplayServer.window_set_vsync_mode(
			DisplayServer.VSYNC_ENABLED if get_value("video", "vsync") else DisplayServer.VSYNC_DISABLED)
	if get_value("video", "fullscreen"):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
