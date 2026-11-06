extends SceneTree
## Leaving a match without a keyboard, in the real scene: the button stays clear of the boards at
## phone sizes, a running game takes a second tap, a finished one doesn't, and Android's back does
## the same while the app itself stays open.
##   godot --headless --path . -s tests/test_leave.gd

# Tests see a screen scale of 1, so the smaller sizes stand in for phones measured in dp.
const SIZES: Array[Vector2i] = [Vector2i(1280, 720), Vector2i(915, 412), Vector2i(412, 915), Vector2i(844, 390), Vector2i(320, 568), Vector2i(600, 600)]
const TITLE := "res://scenes/title.tscn"

var _failed := 0
var _controls: Node
var _net: Node


func _initialize() -> void:
	# Autoloads aren't ready until the first frame.
	await process_frame
	_controls = root.get_node("Controls")
	_net = root.get_node("Net")
	_controls.touch_first = false
	var keyboard: Node = await _start("", "2d")
	_check(keyboard._leave_button.is_visible_in_tree(), "a keyboard or mouse player gets the button too")
	keyboard.free()
	_controls.touch_first = true
	for renderer: String in ["3d", "2d"]:
		for cpu: String in ["", "Overmind"]:
			for size: Vector2i in SIZES:
				await _test_clear_of_boards(size, renderer, cpu)
	root.size = Vector2i(915, 412)
	await _test_running_game_takes_two_taps()
	await _test_second_tap_can_expire()
	await _test_finished_game_takes_one_tap()
	await _test_opponent_gone_takes_one_tap()
	await _test_android_back()
	await _test_tap_on_button_is_not_a_game_tap()
	await _test_pad_leaves_on_start_not_swap()
	print("PASS" if _failed == 0 else "FAIL (%d)" % _failed)
	quit(0 if _failed == 0 else 1)


func _start(cpu: String, renderer := "3d") -> Node:
	# Straight into the loaded file: Config.set_value would save over the player's real settings.
	var config: ConfigFile = root.get_node("Config")._cfg
	config.set_value("video", "renderer", renderer)
	config.set_value("replay", "save", false)
	_net.cpu_name = cpu
	_net.local_idx = 0
	_net.match_seed = 12345
	var game: Node = load("res://scenes/match.tscn").instantiate()
	root.add_child(game)
	current_scene = game # so the scene change to the title replaces it, as in the game
	await process_frame
	await process_frame
	return game


func _test_clear_of_boards(window_size: Vector2i, renderer: String, cpu: String) -> void:
	root.size = window_size
	var game: Node = await _start(cpu, renderer)
	var rect: Rect2 = game._leave_button.get_global_rect()
	var what := "%s %s cpu=%s, button %s on %s" % [window_size, renderer, cpu, rect, root.get_visible_rect().size]
	_check(root.get_visible_rect().encloses(rect), "on screen: " + what)
	var dp: float = _controls.dp_scale()
	_check(rect.size.y >= 48.0 * dp - 0.5 and rect.size.x >= 48.0 * dp - 0.5, "big enough for a finger: " + what)
	var clear := true
	for view: Node in game._views:
		if not view.visible:
			continue
		for i in 9:
			for j in 9:
				var p: Vector2 = rect.position + rect.size * Vector2(i, j) / 8.0
				clear = clear and view.screen_to_cell(p) == Vector2(-1, -1)
	_check(clear, "clear of the boards: " + what)
	game.free()


func _test_running_game_takes_two_taps() -> void:
	var game: Node = await _start("Overmind")
	game._leave_button.pressed.emit()
	_check(game._leave_button.text != "Leave", "the first tap asks")
	await _settle()
	_check(_in_match(game), "the first tap doesn't leave")
	game._leave_button.pressed.emit()
	await _settle()
	_check(_on_title(), "the second tap leaves")
	await _clear()


func _test_second_tap_can_expire() -> void:
	var game: Node = await _start("Overmind")
	game._leave_button.pressed.emit()
	game._leave_asked_msec = Time.get_ticks_msec() - game.LEAVE_CONFIRM_MS
	await process_frame
	_check(game._leave_button.text == "Leave", "the question goes away")
	game._leave_button.pressed.emit()
	await _settle()
	_check(_in_match(game), "so a much later tap asks again")
	game.free()


func _test_finished_game_takes_one_tap() -> void:
	var game: Node = await _start("Overmind")
	game.session.state.winner = 1
	game._leave_button.pressed.emit()
	await _settle()
	_check(_on_title(), "one tap leaves a finished game")
	await _clear()


func _test_opponent_gone_takes_one_tap() -> void:
	var game: Node = await _start("Overmind")
	game._on_opponent_left()
	game._leave_button.pressed.emit()
	await _settle()
	_check(_on_title(), "one tap leaves when the opponent has gone")
	await _clear()


## Android delivers each press twice, so that's what these do.
func _press_back() -> void:
	root.go_back_requested.emit()
	await process_frame
	root.go_back_requested.emit()
	await _settle()


func _test_android_back() -> void:
	var scenes: Node = root.get_node("Scenes")
	_check(not quit_on_go_back, "the engine never quits by itself")
	_check(scenes.back_pressed.get_connections().is_empty(), "with no scene listening, back quits")
	var game: Node = await _start("Overmind")
	await _press_back()
	_check(_in_match(game), "back in a running game asks first")
	_check(game._leave_button.text != "Leave", "and says so")
	await create_timer(scenes.SAME_BACK_PRESS_MS / 1000.0).timeout
	await _press_back()
	_check(_on_title(), "a second press leaves")
	await _clear()
	_check(scenes.back_pressed.get_connections().is_empty(), "and on the title back quits again")
	await create_timer(scenes.SAME_BACK_PRESS_MS / 1000.0).timeout
	var over: Node = await _start("Overmind")
	over.session.state.winner = 1
	root.go_back_requested.emit()
	await _settle() # now on the title, where the same press arrives a second time
	_check(_on_title(), "one press leaves a finished game")
	root.go_back_requested.emit() # would call quit() and end this test without a PASS
	await _clear()


## Through the real viewport, as the phone delivers it: touch then the mouse emulated from it.
func _test_tap_on_button_is_not_a_game_tap() -> void:
	var game: Node = await _start("Overmind")
	game.session.state.winner = 1
	game._over_msec = Time.get_ticks_msec() - game.RETRY_TAP_DELAY_MS
	var seen := []
	var on_start := func() -> void: seen.append("rematch")
	_net.match_started.connect(on_start)
	_touch(game._leave_button.get_global_rect().get_center(), true)
	_touch(game._leave_button.get_global_rect().get_center(), false)
	await _settle()
	_net.match_started.disconnect(on_start)
	_check(seen.is_empty(), "a tap on the button isn't tap-to-retry")
	_check(_on_title(), "it leaves")
	await _clear()


## Through Input and the match's own _process. B is a default swap button, and also Godot-style
## "back" in menus: it must never throw a game away.
func _test_pad_leaves_on_start_not_swap() -> void:
	var game: Node = await _start("Overmind")
	await _pad(JOY_BUTTON_B)
	_check(_in_match(game), "B swaps, and doesn't leave")
	await _pad(JOY_BUTTON_START)
	await _settle()
	_check(_in_match(game), "start asks first, during play")
	_check(game._leave_button.text != "Leave", "and says so")
	await _pad(JOY_BUTTON_START)
	await _settle()
	_check(_on_title(), "a second start leaves")
	await _clear()


func _pad(button: JoyButton) -> void:
	for pressed: bool in [true, false]:
		var ev := InputEventJoypadButton.new()
		ev.button_index = button
		ev.pressed = pressed
		ev.device = 1
		Input.parse_input_event(ev)
		Input.flush_buffered_events()
		await process_frame


func _touch(at: Vector2, pressed: bool) -> void:
	var t := InputEventScreenTouch.new()
	t.position = at
	t.pressed = pressed
	root.push_input(t, true)
	var m := InputEventMouseButton.new()
	m.position = at
	m.global_position = at
	m.button_index = MOUSE_BUTTON_LEFT
	m.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	m.pressed = pressed
	root.push_input(m, true)


func _settle() -> void:
	for i in 3:
		await process_frame


func _in_match(game: Node) -> bool:
	return is_instance_valid(game) and game.is_inside_tree() and not _on_title()


func _on_title() -> bool:
	return current_scene != null and current_scene.scene_file_path == TITLE


## Back to no scene, for the next test.
func _clear() -> void:
	unload_current_scene()
	await process_frame


func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_failed += 1
