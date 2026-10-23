class_name BoardView
## The 2D -> 3D cut-off.
##
## The sim is a 2D integer grid of states and tick timers; it has no idea where
## anything *is* on screen. This turns one board into presentation data: a
## position per block in cell units (x right, y down from the top visible row,
## z toward the viewer) plus flags for flashing/popping/etc. All floats and all
## space live on this side of the line.
##
## Renderers consume only this. The 2D renderer draws z as scale + draw order;
## a 3D renderer can take `pos` straight into a MultiMesh transform. Nothing
## above this file needs to change to switch, and nothing in the sim ever may
## depend on depth — swap arcs, pop bursts and landing squash are purely visual.

const SWAP_DEPTH := 0.45 # cells toward/away from the viewer at mid-swap
const POP_LIFE := 2.0 # pop burst length, in POP_TICKS
const FLASH_PERIOD := 54 # ticks per flash on/off


## One Dictionary per block that should be drawn:
## pos: Vector3, scale: Vector3, color: int (1..COLORS or GARBAGE), gid: int, matched: bool,
## flash: bool, popped: float (0 = intact, >0 = burst progress 0..1), chain: bool
static func blocks(b: SimBoard) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var lift := float(b.rise) / SimConst.ROW_UNITS
	for i in SimBoard.N:
		var c := b.color[i]
		if c == 0:
			continue
		var pos := Vector3(i % SimConst.W, i / SimConst.W - SimConst.BUF - lift, 0.0)
		var scale := Vector3.ONE
		var flash := false
		var popped := 0.0
		var s := b.st[i]
		var t := b.tm[i]
		if s == SimBoard.SWAP_L or s == SimBoard.SWAP_R:
			var p := 1.0 - float(t) / SimConst.SWAP_TICKS
			var dir := 1.0 if s == SimBoard.SWAP_R else -1.0
			pos.x -= dir * (1.0 - p)
			# The panel moving right arcs in front, the one moving left behind.
			pos.z = dir * sin(PI * p) * SWAP_DEPTH
		elif s == SimBoard.FALL:
			pos.y += 1.0 - float(t) / SimConst.FALL_TICKS
		elif s == SimBoard.LAND:
			var k := float(t) / SimConst.LAND_TICKS
			scale = Vector3(1.0 + 0.12 * k, 1.0 - 0.12 * k, 1.0)
		elif s == SimBoard.MATCHED and b.gid[i] != 0:
			# Cracking garbage: flash, then reveal the panel each bottom-row cell becomes,
			# one at a time. Revealed panels hang there until the whole slab is done.
			var pop_at := b.aux[i] & 0xFFFF
			var flash_end := b.aux[i] >> 16
			flash = t > flash_end and (t / FLASH_PERIOD) % 2 == 0
			if t <= pop_at and b.reveal[i] != 0:
				out.append({"pos": pos, "scale": scale, "color": b.reveal[i], "gid": 0, "matched": false,
						"flash": false, "popped": 0.0, "chain": false})
				continue
		elif s == SimBoard.MATCHED:
			var pop_at := b.aux[i] & 0xFFFF
			var flash_end := b.aux[i] >> 16
			flash = t > flash_end and (t / FLASH_PERIOD) % 2 == 0
			if t <= pop_at:
				popped = (pop_at - t) / (SimConst.POP_TICKS * POP_LIFE)
				if popped >= 1.0:
					continue
				pos.z = popped * 0.8
		if pos.y < -1.0:
			continue # still up in the hidden buffer
		out.append({"pos": pos, "scale": scale, "color": c, "gid": b.gid[i], "matched": s == SimBoard.MATCHED,
				"flash": flash, "popped": popped, "chain": b.chain[i] == 1})
	return out


static func lift(b: SimBoard) -> float:
	return float(b.rise) / SimConst.ROW_UNITS


## Cursor's left cell in the same space as blocks (it covers x and x + 1).
static func cursor(b: SimBoard) -> Vector3:
	return Vector3(b.cursor_x, b.cursor_y - SimConst.BUF - lift(b), 0.0)


## Incoming garbage as [w, h] pairs, head first.
static func incoming(b: SimBoard) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for g in b.gar_q:
		out.append(Vector2i(g % 8, g / 8))
	return out


## Per column: 1 if its stack is within two rows of the top (renderers shake these).
static func danger_columns(b: SimBoard) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(SimConst.W)
	for x in SimConst.W:
		for y in range(SimConst.BUF, SimConst.BUF + 2):
			var i := y * SimConst.W + x
			if b.color[i] != 0 and b.st[i] != SimBoard.FALL and b.st[i] != SimBoard.HOVER:
				out[x] = 1
	return out


## Rows of resting garbage stacked above the visible well.
static func overflow_rows(b: SimBoard) -> int:
	for y in SimConst.BUF:
		for x in SimConst.W:
			var i := y * SimConst.W + x
			if b.gid[i] != 0 and b.st[i] != SimBoard.FALL and b.st[i] != SimBoard.HOVER:
				return SimConst.BUF - y
	return 0


## Seconds of grace left while pressed against the top, or -1 when not topped out.
static func grace_seconds(b: SimBoard) -> float:
	return float(b.health) / SimConst.TICK_HZ if b.topped() else -1.0


## 0..1 grace remaining while topped out, 1 otherwise.
static func health(b: SimBoard) -> float:
	return float(b.health) / SimConst.HEALTH_TICKS


## "12 combo" / "x3 chain" callout text while it's live, else "".
static func callout(b: SimBoard) -> String:
	if b.fx_t <= 0:
		return ""
	if b.fx_chain > 1 and b.chain_n > 1:
		return "x%d chain" % b.fx_chain
	if b.fx_combo >= 4:
		return "%d combo" % b.fx_combo
	return ""
