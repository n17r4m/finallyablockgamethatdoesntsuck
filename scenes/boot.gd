extends Node
## First scene. Autoloads are live by now (Config -> Controls -> Net -> Scenes);
## parse launch args, tag the window for multi-instance testing, route on.


func _ready() -> void:
	if OS.has_feature("engine_probe"):
		add_child(load("res://tests/engine_probe.gd").new()) # by path: game builds leave tests out
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--"):
			var kv := arg.substr(2).split("=", true, 1)
			Scenes.launch_args[kv[0]] = kv[1] if kv.size() > 1 else true
	_read_page_args()
	if Scenes.launch_args.has("server"):
		Net.connect_server(str(Scenes.launch_args.server), str(Scenes.launch_args.get("room", "")))
	for role in ["host", "join", "practice"]:
		if Scenes.launch_args.has(role):
			get_window().title += " [%s]" % role
	Scenes.goto(Scenes.TITLE)


## On the web, ?server=wss://...&room=CODE in the page address does what launch args do, which
## is what makes an invite a link.
func _read_page_args() -> void:
	if not OS.has_feature("web"):
		return
	var query: Variant = JavaScriptBridge.eval("window.location.search")
	if not query is String:
		return
	for pair in (query as String).trim_prefix("?").split("&", false):
		var kv := pair.split("=", true, 1)
		if kv[0] in ["server", "room"] and kv.size() == 2:
			Scenes.launch_args[kv[0]] = kv[1].uri_decode()
