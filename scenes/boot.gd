extends Node
## First scene. Autoloads are live by now (Config -> Controls -> Net -> Scenes);
## parse launch args, tag the window for multi-instance testing, route on.


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--"):
			var kv := arg.substr(2).split("=", true, 1)
			Scenes.launch_args[kv[0]] = kv[1] if kv.size() > 1 else true
	for role in ["host", "join", "practice"]:
		if Scenes.launch_args.has(role):
			get_window().title += " [%s]" % role
	Scenes.goto(Scenes.TITLE)
