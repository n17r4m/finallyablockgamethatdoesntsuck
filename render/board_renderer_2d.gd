class_name BoardRenderer2D
extends Node2D
## Placeholder 2D renderer. Reads only BoardView, never sim internals, so a
## BoardRenderer3D can replace it one-for-one. Depth (z) is shown as scale,
## shading and draw order.

const CELL := 40.0
const PALETTE: Array[Color] = [Color.BLACK, Color("e04f5f"), Color("4fc46a"), Color("4f8fe0"),
		Color("e8c547"), Color("a35fd6")]
const GARBAGE_COLOR := Color("8a8f9e")
const BG := Color(0.08, 0.08, 0.12)

var board: SimBoard
var label := ""


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if board == null:
		return
	var font := ThemeDB.fallback_font
	var size := Vector2(SimConst.W, SimConst.H) * CELL
	draw_rect(Rect2(Vector2.ZERO, size), BG)

	# Next row rising in from below, dimmed, clipped to the well.
	var lift := BoardView.lift(board)
	for x in SimConst.W:
		var r := Rect2(x * CELL + 2, (SimConst.H - lift) * CELL, CELL - 4, lift * CELL)
		draw_rect(r, PALETTE[board.next_row[x]].darkened(0.6))

	var blocks := BoardView.blocks(board)
	blocks.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.pos.z < b.pos.z)

	# Intact garbage draws as one slab per gid; converting garbage draws per cell.
	var slabs := {}
	for e in blocks:
		if e.gid != 0 and not e.flash and e.popped == 0.0 and not e.matched:
			var r := Rect2(e.pos.x * CELL, e.pos.y * CELL, CELL, CELL)
			slabs[e.gid] = slabs[e.gid].merge(r) if slabs.has(e.gid) else r
	for r: Rect2 in slabs.values():
		draw_rect(r.grow(-2), GARBAGE_COLOR)
		draw_rect(r.grow(-6), GARBAGE_COLOR.darkened(0.25), false, 2.0)

	for e in blocks:
		if e.gid != 0 and slabs.has(e.gid) and not e.matched:
			continue
		var center := (Vector2(e.pos.x, e.pos.y) + Vector2(0.5, 0.5)) * CELL
		var k: float = 1.0 + e.pos.z * 0.35
		var sz := Vector2(CELL * e.scale.x, CELL * e.scale.y) * k - Vector2(4, 4)
		var base: Color = GARBAGE_COLOR.lightened(0.2) if e.gid != 0 else PALETTE[e.color]
		if e.popped > 0.0:
			var grow: float = 1.0 + e.popped
			draw_rect(Rect2(center - sz * grow / 2, sz * grow), Color(base, 1.0 - e.popped), false, 3.0)
			continue
		var c := Color.WHITE if e.flash else base
		if e.matched and not e.flash:
			c = c.lightened(0.35)
		if e.pos.z < 0.0:
			c = c.darkened(-e.pos.z)
		draw_rect(Rect2(center - sz / 2, sz), c)

	# Mask anything poking up out of the hidden buffer.
	draw_rect(Rect2(-4, -CELL - 4, size.x + 8, CELL + 4), RenderingServer.get_default_clear_color())

	var cur := BoardView.cursor(board)
	draw_rect(Rect2(cur.x * CELL, cur.y * CELL, CELL * 2, CELL), Color.WHITE, false, 3.0)

	draw_string(font, Vector2(0, -16), "%s   %d%s" % [label, board.score,
			"   TOPPED OUT" if board.lost else ""], HORIZONTAL_ALIGNMENT_LEFT, -1, 20)
	var incoming := BoardView.incoming(board)
	if not incoming.is_empty():
		var txt := " ".join(incoming.map(func(v: Vector2i) -> String: return "%dx%d" % [v.x, v.y]))
		draw_string(font, Vector2(0, -44), "incoming " + txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, GARBAGE_COLOR)
	var callout := BoardView.callout(board)
	if callout != "":
		draw_string(font, Vector2(0, size.y + 34), callout, HORIZONTAL_ALIGNMENT_CENTER, size.x, 26,
				Color("e8c547"))
