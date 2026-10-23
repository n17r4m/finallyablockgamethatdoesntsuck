class_name BoardRenderer3D
extends Node3D
## 3D renderer. Same BoardView feed as BoardRenderer2D: blocks are MultiMesh
## instances placed straight from BoardView positions, so swap arcs, pop bursts
## and landing squash come through with real depth. One unit = one cell.

const PALETTE: Array[Color] = [Color.BLACK, Color("e04f5f"), Color("4fc46a"), Color("4f8fe0"),
		Color("e8c547"), Color("a35fd6")]
const GARBAGE_COLOR := Color("8a8f9e")
const W := SimConst.W
const H := SimConst.H
const SHAKE_HZ := 9.0
const WELL_COLOR := Color(0.07, 0.07, 0.11)
const BULLET_COLOR := Color(0.05, 0.11, 0.26)

var board: SimBoard
var label := ""

var _mm: MultiMesh
var _cursor: Node3D
var _title: Label3D
var _callout: Label3D
var _incoming: Label3D
var _warning: Label3D
var _well_mat: StandardMaterial3D
var _clock := 0.0


func _ready() -> void:
	var well := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(W + 0.3, H + 0.3)
	well.mesh = quad
	well.position = Vector3(0, 0, -0.46) # flush behind the blocks so perspective can't slide it
	_well_mat = _unshaded(WELL_COLOR)
	well.material_override = _well_mat
	add_child(well)

	var box := BoxMesh.new()
	box.size = Vector3(0.9, 0.9, 0.9)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.3
	box.material = mat
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.mesh = box
	_mm.instance_count = SimBoard.N + W
	_mm.visible_instance_count = 0
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _mm
	add_child(mmi)

	# Cursor: a frame of four thin bars around two cells.
	_cursor = Node3D.new()
	add_child(_cursor)
	var white := _unshaded(Color.WHITE)
	for bar: Array in [[Vector3(0, 0.5, 0), Vector3(2.08, 0.08, 0.08)], [Vector3(0, -0.5, 0), Vector3(2.08, 0.08, 0.08)],
			[Vector3(-1, 0, 0), Vector3(0.08, 1.08, 0.08)], [Vector3(1, 0, 0), Vector3(0.08, 1.08, 0.08)]]:
		var m := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = bar[1]
		m.mesh = bm
		m.position = bar[0] + Vector3(0, 0, 0.5)
		m.material_override = white
		_cursor.add_child(m)

	_title = _label(Vector3(-W / 2.0, H / 2.0 + 0.7, 0), 40, HORIZONTAL_ALIGNMENT_LEFT)
	_incoming = _label(Vector3(-W / 2.0, H / 2.0 + 1.3, 0), 32, HORIZONTAL_ALIGNMENT_LEFT)
	_incoming.modulate = GARBAGE_COLOR
	_callout = _label(Vector3(0, -H / 2.0 + 2.0, 1.5), 72, HORIZONTAL_ALIGNMENT_CENTER) # floats in front of the stack
	_callout.modulate = Color("e8c547")
	_warning = _label(Vector3(0, H / 2.0 - 0.6, 0.8), 48, HORIZONTAL_ALIGNMENT_CENTER) # inside the well's top
	_warning.modulate = Color("ff5a5a")


func _process(delta: float) -> void:
	_clock += delta
	if board == null:
		return
	_well_mat.albedo_color = WELL_COLOR.lerp(BULLET_COLOR, BoardView.slowmo(board))
	var danger := BoardView.danger_columns(board)
	var shake := absf(sin(_clock * TAU * SHAKE_HZ)) * 0.12 * (1.5 - BoardView.health(board))
	var n := 0
	for e in BoardView.blocks(board):
		var p: Vector3 = e.pos
		if e.gid == 0 and danger[int(p.x + 0.5) % W]:
			p.y -= shake
		var c: Color = GARBAGE_COLOR if e.gid != 0 else PALETTE[e.color]
		if e.flash:
			c = Color.WHITE
		elif e.matched:
			c = c.lightened(0.35)
		var s: Vector3 = e.scale * (1.0 + e.popped * 0.8)
		c.a = (1.0 - e.popped) * clampf(1.0 + 2.5 * p.y, 0.0, 1.0) # fade out fast above the top edge
		_mm.set_instance_transform(n, Transform3D(Basis.from_scale(s), _to3d(p)))
		_mm.set_instance_color(n, c)
		n += 1
	# Next row creeping up from below, dimmed.
	var lift := BoardView.lift(board)
	for x in W:
		_mm.set_instance_transform(n, Transform3D(Basis(), _to3d(Vector3(x, H - lift, 0))))
		_mm.set_instance_color(n, PALETTE[board.next_row[x]].darkened(0.65))
		n += 1
	_mm.visible_instance_count = n

	_cursor.position = _to3d(BoardView.cursor(board)) + Vector3(0.5, 0, 0)
	_title.text = "%s  %d" % [label, board.score]
	var incoming := BoardView.incoming(board)
	_incoming.text = "" if incoming.is_empty() else "incoming " + " ".join(
			incoming.map(func(v: Vector2i) -> String: return "%dx%d" % [v.x, v.y]))
	_callout.text = BoardView.callout(board)
	var warn := PackedStringArray()
	var over := BoardView.overflow_rows(board)
	if over > 0:
		warn.append("+%d above" % over)
	var grace := BoardView.grace_seconds(board)
	if grace >= 0.0:
		warn.append("%.1fs" % grace)
	_warning.text = "  ".join(warn)


## Screen point -> cell units (x right from the left edge, y down from the top
## visible row; y >= H is the rising row), or (-1, -1) off the board. Casts
## through the camera onto the board's plane.
func screen_to_cell(screen: Vector2) -> Vector2:
	var cam := get_viewport().get_camera_3d()
	if cam == null or board == null:
		return Vector2(-1, -1)
	var inv := global_transform.affine_inverse()
	var o := inv * cam.project_ray_origin(screen)
	var d := inv.basis * cam.project_ray_normal(screen)
	if absf(d.z) < 1e-6:
		return Vector2(-1, -1)
	var hit := o + d * (-o.z / d.z)
	var p := Vector2(hit.x + W / 2.0, H / 2.0 - hit.y + BoardView.lift(board))
	if p.x < 0.0 or p.x >= W or p.y < 0.0 or p.y >= H + 1:
		return Vector2(-1, -1)
	return p


## BoardView cell space (y down from the top visible row) -> local 3D (y up, centred).
func _to3d(p: Vector3) -> Vector3:
	return Vector3(p.x - W / 2.0 + 0.5, H / 2.0 - 0.5 - p.y, p.z)


func _label(pos: Vector3, size: int, align: HorizontalAlignment) -> Label3D:
	var l := Label3D.new()
	l.position = pos
	l.font_size = size
	l.pixel_size = 0.01
	l.horizontal_alignment = align
	l.outline_size = 12
	l.outline_modulate = Color(0, 0, 0, 0.8)
	add_child(l)
	return l


func _unshaded(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	return m
