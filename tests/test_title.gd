extends SceneTree
## The title menu in the real scene: centred on screen, in reach and sized for fingers.
##   godot --headless --path . -s tests/test_title.gd

# Tests see a screen scale of 1, so the smaller sizes stand in for phones measured in dp.
const SIZES: Array[Vector2i] = [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(412, 915), Vector2i(915, 412), Vector2i(320, 568)]
const TAP_HEIGHT := 48.0

var _failed := 0


func _initialize() -> void:
	# Autoloads aren't ready until the first frame.
	await process_frame
	var controls: Node = root.get_node("Controls")
	_check(not controls.touch_first, "a desktop isn't touch-first, though the mouse emulates touch")
	for touch: bool in [false, true]:
		controls.touch_first = touch
		for size: Vector2i in SIZES:
			await _test_menu(size, touch)
	print("PASS" if _failed == 0 else "FAIL (%d)" % _failed)
	quit(0 if _failed == 0 else 1)


func _test_menu(window_size: Vector2i, touch: bool) -> void:
	root.size = window_size
	var title: Control = load("res://scenes/title.tscn").instantiate()
	root.add_child(title)
	await process_frame
	await process_frame
	var view := root.get_visible_rect()
	var box: Control = title.get_child(0).get_child(0).get_child(0)
	var rect := box.get_global_rect()
	var what := "%s touch=%s, menu %s on %s" % [window_size, touch, rect, view.size]
	_check(title.get_global_rect().size.is_equal_approx(view.size), "title fills the screen: " + what)
	if rect.size.y <= view.size.y:
		_check(absf(rect.get_center().x - view.get_center().x) < 1.0, "centred across: " + what)
		_check(absf(rect.get_center().y - view.get_center().y) < 1.0, "centred down: " + what)
		_check(view.encloses(rect), "fully on screen: " + what)
	else: # too tall for the screen, so it scrolls; a scrollbar takes a little of the width
		_check(rect.position.x >= 0.0 and rect.end.x <= view.end.x, "fits across: " + what)
		_check(rect.position.y >= 0.0, "scrolls from its top: " + what)
	if touch:
		for c: Control in title.find_children("*", "BaseButton", true, false) + title.find_children("*", "LineEdit", true, false):
			if c.is_visible_in_tree(): # option buttons hide a search box in their popups
				_check(c.size.y >= TAP_HEIGHT, "%s is tappable: %s" % [c.get_class(), what])
	title.free()
	_check(is_equal_approx(root.content_scale_factor, 1.0), "the match gets project units back: " + what)
	root.content_scale_factor = 1.0


func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_failed += 1
