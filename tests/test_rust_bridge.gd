extends SceneTree
## Runs the engine probe here. tools/build_rust_ext.sh linux must have built the extension.
##   godot --headless --path . -s tests/test_rust_bridge.gd


func _init() -> void:
	var probe := EngineProbe.new()
	probe.finished.connect(func(failed: int) -> void: quit(0 if failed == 0 else 1))
	root.add_child.call_deferred(probe)
