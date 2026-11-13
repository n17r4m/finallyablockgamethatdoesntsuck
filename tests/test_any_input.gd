extends SceneTree
## The UI for whichever input the player is using, in the real scenes: hints follow the last one
## used, every way out and every retry works from every device, the hint stays clear of the board
## and goes when the game starts, and each platform gets only the buttons it can use.
##   godot --headless --path . -s tests/test_any_input.gd

# Tests see a screen scale of 1, so the smaller sizes stand in for phones measured in dp.
const SIZES: Array[Vector2i] = [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(800, 600),
		Vector2i(800, 484), Vector2i(915, 412), Vector2i(800, 360), Vector2i(412, 915),
		Vector2i(360, 800), Vector2i(320, 568), Vector2i(768, 1024), Vector2i(600, 600)]
const TITLE := "res://scenes/title.tscn"

const EXPECTED_CHECKS := 1193
var _failed := 0
var _ran := 0
var _controls: Node
var _net: Node
var _config: Node


func _initialize() -> void:
	await process_frame # autoloads aren't ready until the first frame
	_controls = root.get_node("Controls")
	_controls.pretend_pad = 0 # a pad plugged into this machine mustn't change what is tested
	_net = root.get_node("Net")
	_config = root.get_node("Config")
	_config._cfg.set_value("replay", "save", false) # in memory: set_value would write the player's file
	_test_last_device()
	_test_hint_words()
	for renderer: String in ["3d", "2d"]:
		for size: Vector2i in SIZES:
			for setup: Array in [["Overmind", 0], ["Overmind", 1], ["", 0]]:
				await _test_hint_placement(renderer, size, setup[0], setup[1])
	root.size = Vector2i(1280, 720)
	await _test_hint_only_in_the_countdown()
	await _test_escape_asks()
	await _test_click_retries_on_a_desktop()
	await _test_click_on_leave_is_not_a_retry()
	await _test_end_text_follows_the_device()
	await _test_platform_buttons()
	await _test_focus_starts_on_play()
	await _test_keyboard_on_a_touch_screen_finds_the_menu()
	await _test_grab_setting()
	await _test_pointer_in_the_real_match()
	# The audio server lets go of a stopped sound on its own thread: give it a moment, or a
	# cursor click from the last match is still held when we quit.
	await create_timer(0.2).timeout
	_failed += absi(EXPECTED_CHECKS - _ran) # a script error stops a test without failing a check
	print("PASS" if _failed == 0 else "FAIL (%d of %d checks ran, %d failed or missing)" % [_ran, EXPECTED_CHECKS, _failed])
	quit(0 if _failed == 0 else 1)


func _check(ok: bool, what: String) -> void:
	_ran += 1
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_failed += 1


func _send(ev: InputEvent) -> void:
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _key_press(code: Key, pressed := true) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = pressed
	return ev


func _test_last_device() -> void:
	_controls.last_device = ""
	_controls.touch_first = false
	_check(_controls.hint_device() == "keys", "a desktop starts by talking about keys")
	_controls.touch_first = true
	_check(_controls.hint_device() == "touch", "a touch screen, about touch")
	_controls.touch_first = false

	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_A
	pad.pressed = true
	_controls._input(pad)
	_check(_controls.hint_device() == "pad", "a pad button makes it the pad")
	_controls._input(_key_press(KEY_Z, false))
	_check(_controls.hint_device() == "pad", "a key let go isn't using the keys")
	_controls._input(_key_press(KEY_Z))
	_check(_controls.hint_device() == "keys", "a key press is")

	var small := InputEventJoypadMotion.new()
	small.axis = JOY_AXIS_LEFT_X
	small.axis_value = 0.1
	_controls._input(small)
	_check(_controls.hint_device() == "keys", "a stick resting a little off centre isn't using the pad")
	small.axis_value = 0.9
	_controls._input(small)
	_check(_controls.hint_device() == "pad", "pushing it is")

	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = true
	_controls._input(mouse)
	_check(_controls.hint_device() == "mouse", "a mouse press makes it the mouse")
	var moved := InputEventMouseMotion.new()
	_controls.last_device = "keys"
	_controls._input(moved)
	_check(_controls.hint_device() == "keys", "the mouse being knocked doesn't")

	# What the engine sends for one click: the press, and a touch copied from it.
	var copy := InputEventScreenTouch.new()
	copy.pressed = true
	copy.device = InputEvent.DEVICE_ID_EMULATION
	_controls.last_device = "mouse"
	_controls._input(copy)
	_check(_controls.hint_device() == "mouse", "a mouse's copied touch isn't a finger")
	# And for one tap: the touch, and a mouse press copied from it.
	var finger := InputEventScreenTouch.new()
	finger.pressed = true
	_controls._input(finger)
	_check(_controls.hint_device() == "touch", "a real touch is")
	var mouse_copy := InputEventMouseButton.new()
	mouse_copy.button_index = MOUSE_BUTTON_LEFT
	mouse_copy.pressed = true
	mouse_copy.device = InputEvent.DEVICE_ID_EMULATION
	_controls._input(mouse_copy)
	_check(_controls.hint_device() == "touch", "and its copied mouse press isn't a mouse")
	_controls.last_device = ""


func _test_hint_words() -> void:
	_controls.grab_mode = false
	_controls.last_device = "keys"
	_check(_controls.hint().contains("Space/X swap"), "keys, swap: " + _controls.hint())
	_check(_controls.hint().ends_with("esc leave"), "and how to leave")
	_controls.last_device = "pad"
	_check(_controls.hint().contains("A/B swap"), "pad, swap: " + _controls.hint())
	_check(_controls.hint().ends_with("start leave"), "and how to leave")
	_controls.last_device = "touch"
	_check(_controls.hint().contains("tap between two blocks to swap"), "touch: " + _controls.hint())
	_controls.last_device = "mouse"
	_check(_controls.hint().contains("click between two blocks to swap"), "mouse: " + _controls.hint())
	_controls.grab_mode = true
	_controls.last_device = "keys"
	_check(_controls.hint().contains("Space/X hold to grab"), "keys, grab: " + _controls.hint())
	_controls.last_device = "pad"
	_check(_controls.hint().contains("A/B hold to grab"), "pad, grab: " + _controls.hint())
	_controls.last_device = "touch"
	_check(_controls.hint().contains("drag a block to carry"), "touch, grab: " + _controls.hint())
	_controls.grab_mode = false
	_controls.last_device = ""


func _start(cpu: String, idx := 0) -> Node:
	_net.remote_id = 0
	_net.local_idx = idx
	_net.match_seed = 5
	_net.cpu_name = cpu
	_net.cpu_level = "normal"
	_net.demo = false
	var game: Node = load("res://scenes/match.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	await process_frame
	await process_frame
	return game


func _test_hint_placement(renderer: String, size: Vector2i, cpu: String, idx: int) -> void:
	_config._cfg.set_value("video", "renderer", renderer)
	root.size = size
	var game: Node = await _start(cpu, idx)
	var what := "%s %s cpu=%s p%d" % [renderer, size, cpu, idx]
	var rect: Rect2 = game._hint_rect()
	var view := root.get_visible_rect()
	var font := ThemeDB.fallback_font
	for device: String in ["keys", "pad", "touch", "mouse"]:
		_controls.last_device = device
		var used := font.get_multiline_string_size(game._hint_text(), HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, game._hint_size())
		var text := Rect2(rect.position, Vector2(rect.size.x, used.y))
		_check(view.encloses(text), "%s: %s hint on screen, %s in %s" % [what, device, text, view.size])
		_check(used.y <= rect.size.y + 1.0, "%s: %s hint fits its space, %d of %d tall" % [what, device, used.y, rect.size.y])
		_check(game._leave_button.get_global_rect().intersection(text).size == Vector2.ZERO, "%s: %s hint clear of Leave" % [what, device])
		_check(_clear_of_blocks(game, text), "%s: %s hint clear of every block, %s" % [what, device, text])
		var widest := 0.0
		for line: String in game._hint_text().split("\n"):
			widest = maxf(widest, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, game._hint_size()).x)
		if device == "keys":
			_check(widest <= rect.size.x * 1.5, "%s: lines mostly fit across, %d of %d" % [what, widest, rect.size.x])
	_controls.last_device = ""
	game.free()


## The hint's corners and edges, on every board on show. On a narrow screen it's in the well's
## top rows, which are empty until the game starts, so what counts there is staying in them.
func _clear_of_blocks(game: Node, text: Rect2) -> bool:
	var narrow: bool = game._narrow(root.get_visible_rect().size)
	for view: Node in game._views:
		if not view.visible:
			continue
		for i in 9:
			for j in 9:
				var cell: Vector2 = view.screen_to_cell(text.position + text.size * Vector2(i, j) / 8.0)
				if cell == Vector2(-1, -1):
					continue
				if not narrow or view != game._views[game.session.local_idx] or cell.y > _start_stack_top(view):
					return false
	return true


func _start_stack_top(view: Node) -> float:
	var b: SimBoard = view.board
	for row in SimConst.H:
		for x in SimConst.W:
			if b.color[(SimConst.BUF + row) * SimConst.W + x] != 0:
				return float(row)
	return float(SimConst.H)


func _test_hint_only_in_the_countdown() -> void:
	var game: Node = await _start("Overmind")
	_check(game._hint_showing(), "the hint shows in the countdown")
	game.session.state.tick = SimConst.COUNTDOWN_TICKS
	_check(not game._hint_showing(), "and not once the game starts")
	game.free()


func _test_escape_asks() -> void:
	var game: Node = await _start("Overmind")
	_check(game._leave_button.visible, "Leave is there for a keyboard player, so Sure? has somewhere to show")
	_send(_key_press(KEY_ESCAPE))
	await process_frame
	_send(_key_press(KEY_ESCAPE, false))
	await _settle()
	_check(_in_match(game), "esc in a running game doesn't leave")
	_check(game._leave_button.text == "Sure?", "it asks")
	_send(_key_press(KEY_ESCAPE))
	await process_frame
	_send(_key_press(KEY_ESCAPE, false))
	await _settle()
	_check(_on_title(), "and a second esc leaves")
	await _clear()

	game = await _start("Overmind")
	game.session.state.winner = 1
	_send(_key_press(KEY_ESCAPE))
	await process_frame
	_send(_key_press(KEY_ESCAPE, false))
	await _settle()
	_check(_on_title(), "one esc leaves a finished game")
	await _clear()

	game = await _start("Overmind")
	game._on_opponent_left()
	_send(_key_press(KEY_ESCAPE))
	await process_frame
	_send(_key_press(KEY_ESCAPE, false))
	await _settle()
	_check(_on_title(), "and a game the opponent has left")
	await _clear()


## As a real mouse arrives: the press, and the touch the engine copies from it.
func _click(at: Vector2, pressed := true) -> void:
	var m := InputEventMouseButton.new()
	m.position = at
	m.global_position = at
	m.button_index = MOUSE_BUTTON_LEFT
	m.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	m.pressed = pressed
	_controls.last_device = "mouse"
	root.push_input(m, true)
	var t := InputEventScreenTouch.new()
	t.position = at
	t.pressed = pressed
	t.device = InputEvent.DEVICE_ID_EMULATION
	root.push_input(t, true)


func _test_click_retries_on_a_desktop() -> void:
	_controls.touch_first = false
	var game: Node = await _start("Overmind")
	var seen := []
	var on_start := func() -> void: seen.append("rematch")
	_net.match_started.connect(on_start)
	game.session.state.winner = 1
	await process_frame
	_click(Vector2(640, 360))
	_click(Vector2(640, 360), false)
	await _settle()
	_check(seen.is_empty(), "too soon after the end, a click is a player still playing")
	game._over_msec = Time.get_ticks_msec() - game.RETRY_TAP_DELAY_MS
	_click(Vector2(640, 360))
	_click(Vector2(640, 360), false)
	await _settle()
	_check(seen.size() == 1, "a click retries, with no touch screen in sight")
	_net.match_started.disconnect(on_start)
	await _clear()
	_clear_scenes()


func _test_click_on_leave_is_not_a_retry() -> void:
	var game: Node = await _start("Overmind")
	game.session.state.winner = 1
	game._over_msec = Time.get_ticks_msec() - game.RETRY_TAP_DELAY_MS
	var seen := []
	var on_start := func() -> void: seen.append("rematch")
	_net.match_started.connect(on_start)
	var at: Vector2 = game._leave_button.get_global_rect().get_center()
	_click(at)
	_click(at, false)
	await _settle()
	_net.match_started.disconnect(on_start)
	_check(seen.is_empty(), "a click on Leave isn't a retry")
	_check(_on_title(), "it leaves")
	await _clear()


func _test_end_text_follows_the_device() -> void:
	var game: Node = await _start("Overmind")
	_controls.last_device = "keys"
	_check(game._retry_text().contains("swap for retry") and game._retry_text().contains("esc for title"), "keys: " + game._retry_text())
	_controls.last_device = "pad"
	_check(game._retry_text().contains("start for title"), "pad: " + game._retry_text())
	_controls.last_device = "mouse"
	_check(game._retry_text().contains("click for retry"), "mouse: " + game._retry_text())
	_controls.last_device = "touch"
	_check(game._retry_text().contains("tap for retry"), "touch: " + game._retry_text())
	_controls.last_device = ""
	game.free()


func _title(can_host := true, can_quit := true) -> Control:
	var title: Control = load(TITLE).instantiate()
	title.can_host = can_host
	title.can_quit = can_quit
	root.add_child(title)
	await process_frame
	await process_frame
	return title


func _button_named(title: Control, text: String) -> Button:
	for b: Button in title.find_children("*", "Button", true, false):
		if b.text == text and b.is_visible_in_tree():
			return b
	return null


func _test_platform_buttons() -> void:
	var desktop: Control = await _title()
	_check(_button_named(desktop, "Host") != null and _button_named(desktop, "Quit") != null, "a desktop can host and quit")
	desktop.free()
	var web: Control = await _title(false, false)
	_check(_button_named(web, "Host") == null, "a page has no Host: it can't listen")
	_check(_button_named(web, "Quit") == null, "and no Quit")
	_check(_button_named(web, "Join") != null, "but can still join")
	web.free()
	var phone: Control = await _title(true, false)
	_check(_button_named(phone, "Host") != null, "a phone can host")
	_check(_button_named(phone, "Quit") == null, "and has no Quit")
	phone.free()
	root.content_scale_factor = 1.0


func _test_focus_starts_on_play() -> void:
	_controls.touch_first = false
	var title: Control = await _title()
	_check(root.gui_get_focus_owner() == title._play, "a keyboard starts on Play")
	var accept := _key_press(KEY_ENTER)
	var seen := []
	var on_start := func() -> void: seen.append("start")
	_net.match_started.connect(on_start)
	Input.parse_input_event(accept)
	Input.flush_buffered_events()
	await process_frame
	_send(_key_press(KEY_ENTER, false))
	await process_frame
	_net.match_started.disconnect(on_start)
	_check(seen.size() == 1, "and Enter starts a game")
	_net.leave()
	if is_instance_valid(title):
		title.free()
	await process_frame
	root.content_scale_factor = 1.0
	_clear_scenes()


func _test_keyboard_on_a_touch_screen_finds_the_menu() -> void:
	_controls.touch_first = true
	var title: Control = await _title()
	_check(root.gui_get_focus_owner() == null, "a touch screen starts with nothing focused")
	_send(_key_press(KEY_DOWN))
	await process_frame
	_send(_key_press(KEY_DOWN, false))
	await process_frame
	_check(root.gui_get_focus_owner() == title._play, "and a keyboard's first key finds the menu")
	_controls.touch_first = false
	title.free()
	root.content_scale_factor = 1.0


func _test_grab_setting() -> void:
	_controls.grab_mode = false
	var title: Control = await _title()
	title._settings.pressed.emit()
	await _settle()
	var menu: Control = title.get_child(-1)
	menu._set_cursor("grab")
	_check(_controls.grab_mode, "the setting turns the grab cursor on")
	_check(_config.get_value("controls", "cursor") == "grab", "and is kept")
	var pages: Array = []
	for tab: Button in menu._tabs.get_children():
		pages.append(tab.text)
	_check("Cursor" in pages, "it has a page: %s" % [pages])
	for renderer: String in ["3d", "2d"]:
		_config._cfg.set_value("video", "renderer", renderer)
		var game: Node = await _start("Overmind")
		await process_frame
		var mine: Node = game._views[0]
		_check(mine.cursor_cell.x >= 0, "%s draws your cursor one block wide" % renderer)
		_check(game._views[1].cursor_cell.x < 0, "%s leaves the opponent's as the sim has it" % renderer)
		game.free()
	menu._set_cursor("swap")
	_check(not _controls.grab_mode, "and off again")
	for renderer: String in ["3d", "2d"]:
		_config._cfg.set_value("video", "renderer", renderer)
		var game: Node = await _start("Overmind")
		await process_frame
		_check(game._views[0].cursor_cell.x < 0, "%s goes back to two blocks" % renderer)
		game.free()
	title.free()
	root.content_scale_factor = 1.0
	_clear_scenes()


## A real mouse movement through the viewport, on each renderer and cursor, where the board is drawn.
func _test_pointer_in_the_real_match() -> void:
	for renderer: String in ["3d", "2d"]:
		_config._cfg.set_value("video", "renderer", renderer)
		for grab: bool in [false, true]:
			_controls.grab_mode = grab
			var game: Node = await _start("Overmind")
			var what := "%s grab=%s" % [renderer, grab]
			var mine: Node = game._views[0]
			var before: int = game.session.state.boards[0].cursor_x
			await process_frame
			_check(game.session.state.boards[0].cursor_x == before, "%s: nothing moves the cursor until the pointer does" % what)
			var m := InputEventMouseMotion.new()
			m.position = mine.cell_to_screen(Vector2(4.6, 3.5)) # nearest the boundary before column 5
			root.push_input(m, true)
			await _settle()
			var b: SimBoard = game.session.state.boards[0]
			_check(b.cursor_x == 4 and b.cursor_y == SimBoard.TOP + 3, "%s: the board's cursor is under the pointer: (%d, %d)" % [what, b.cursor_x, b.cursor_y - SimBoard.TOP])
			if grab:
				_check(mine.cursor_cell == Vector2i(4, 3), "%s: and it's drawn there: %s" % [what, mine.cursor_cell])
			m = InputEventMouseMotion.new()
			m.position = game._leave_button.get_global_rect().get_center()
			root.push_input(m, true)
			await _settle()
			b = game.session.state.boards[0]
			_check(b.cursor_x == 4 and b.cursor_y == SimBoard.TOP + 3, "%s: going to the Leave button leaves the cursor behind" % what)
			game.free()
	_controls.grab_mode = false


func _settle() -> void:
	for i in 3:
		await process_frame


func _in_match(game: Variant) -> bool: # untyped, or a game already freed is a script error
	return is_instance_valid(game) and game.is_inside_tree() and not _on_title()


func _on_title() -> bool:
	return current_scene != null and current_scene.scene_file_path == TITLE


func _clear() -> void:
	unload_current_scene()
	await process_frame
	root.content_scale_factor = 1.0


## Anything a scene change left behind, so the next test starts clean.
func _clear_scenes() -> void:
	for child: Node in root.get_children():
		if child.scene_file_path != "":
			child.free()
	current_scene = null
