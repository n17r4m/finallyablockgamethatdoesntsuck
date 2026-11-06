extends Node
## Persistent settings in user://settings.cfg. Autoload #1: everything after reads from here.

const PATH := "user://settings.cfg"
const DEFAULTS := {
	"player": {"name": "Player"},
	"net": {"address": "127.0.0.1", "port": 47100, "transport": "enet", "input_delay_frames": 2},
	"replay": {"save": true, "keep": 50},
	"sim": {"backend": "auto"}, # "auto" uses the Rust rules where available, "gdscript" never does
	"video": {"fullscreen": false, "vsync": true, "max_fps": 0, "renderer": "3d", "show_stats": true},
	"audio": {"master": 1.0, "music": 1.0, "sfx": 1.0}, # 0..1
	"controls": {"stick_deadzone": 0.5, "carry_delay_ms": 110},
}
## Audio buses by setting. Sounds play on "Music" or "SFX"; both feed Master.
const BUSES := {"master": "Master", "music": "Music", "sfx": "SFX"}

## Where settings are saved; empty keeps them in memory.
var path := PATH
var _cfg := ConfigFile.new()


func _ready() -> void:
	# A test or tool (godot -s) gets the defaults and leaves the player's own settings alone.
	if Engine.get_main_loop().get_script() != null:
		path = ""
	else:
		_cfg.load(path) # missing file is fine; defaults fill in
	_add_audio_buses()
	apply()


func get_value(section: String, key: String) -> Variant:
	return _cfg.get_value(section, key, DEFAULTS[section][key])


## For sections whose defaults live elsewhere, like the bindings in Controls.
func get_or(section: String, key: String, fallback: Variant) -> Variant:
	return _cfg.get_value(section, key, fallback)


func set_value(section: String, key: String, value: Variant) -> void:
	_cfg.set_value(section, key, value)
	_save()


func erase_section(section: String) -> void:
	if _cfg.has_section(section):
		_cfg.erase_section(section)
		_save()


func _save() -> void:
	if path != "":
		_cfg.save(path)


func apply() -> void:
	apply_audio()
	if can_limit_fps():
		Engine.max_fps = get_value("video", "max_fps")
	if can_set_vsync():
		DisplayServer.window_set_vsync_mode(
				DisplayServer.VSYNC_ENABLED if get_value("video", "vsync") else DisplayServer.VSYNC_DISABLED)
		# Not on the web, where a page can't go fullscreen until the player does something.
		if get_value("video", "fullscreen") != is_fullscreen():
			set_fullscreen(get_value("video", "fullscreen"))


func apply_audio() -> void:
	for key: String in BUSES:
		AudioServer.set_bus_volume_linear(AudioServer.get_bus_index(BUSES[key]), get_value("audio", key))


func _add_audio_buses() -> void:
	for key: String in BUSES:
		if AudioServer.get_bus_index(BUSES[key]) == -1:
			AudioServer.add_bus()
			var bus := AudioServer.bus_count - 1
			AudioServer.set_bus_name(bus, BUSES[key])
			AudioServer.set_bus_send(bus, "Master")


func is_fullscreen() -> bool:
	var mode := DisplayServer.window_get_mode()
	return mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN


func set_fullscreen(on: bool) -> void:
	set_value("video", "fullscreen", on)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED)


## Phone apps always fill the screen.
func can_set_fullscreen() -> bool:
	return OS.has_feature("web") or not OS.has_feature("mobile")


## The browser and the phone decide this themselves.
func can_set_vsync() -> bool:
	return not OS.has_feature("web") and not OS.has_feature("mobile")


## The browser paces the game itself.
func can_limit_fps() -> bool:
	return not OS.has_feature("web")
