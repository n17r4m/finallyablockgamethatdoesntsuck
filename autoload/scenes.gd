extends Node
## Scene routing plus launch args (`godot --path . -- --host`, `-- --join=1.2.3.4`, `-- --practice`).

const TITLE := "res://scenes/title.tscn"
const MATCH := "res://scenes/match.tscn"
const SAME_BACK_PRESS_MS := 500

## Android's back. A scene that connects decides what it means; with none, it quits the app.
signal back_pressed

var launch_args := {}
var _back_msec := -SAME_BACK_PRESS_MS


func _ready() -> void:
	# Any match start — first game, rematch, practice retry — lands in a fresh match scene.
	Net.match_started.connect(goto.bind(MATCH))
	get_tree().quit_on_go_back = false
	get_window().go_back_requested.connect(_on_go_back)


func goto(path: String) -> void:
	get_tree().change_scene_to_file.call_deferred(path)


## One press arrives twice, as the key event and as the activity's back. Answering here, not in
## each scene, also stops the second half from quitting from the title the first half led to.
func _on_go_back() -> void:
	var now := Time.get_ticks_msec()
	if now - _back_msec < SAME_BACK_PRESS_MS:
		return
	_back_msec = now
	if back_pressed.get_connections().is_empty():
		get_tree().quit()
	else:
		back_pressed.emit()
