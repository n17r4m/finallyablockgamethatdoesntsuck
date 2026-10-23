extends Node
## Scene routing plus launch args (`godot --path . -- --host`, `-- --join=1.2.3.4`, `-- --practice`).

const TITLE := "res://scenes/title.tscn"
const MATCH := "res://scenes/match.tscn"

var launch_args := {}


func goto(path: String) -> void:
	get_tree().change_scene_to_file.call_deferred(path)
