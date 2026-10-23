class_name SimBoard
extends RefCounted
## One player's well. Integer-only and allocation-light: it steps 1080x/s and
## gets re-simulated during rollback, so keep the per-tick path cheap.

const W := SimConst.W
const H := SimConst.H

var cells := PackedByteArray() # 0 = empty, 1..COLORS; row-major, y = 0 is the top
var clear_t := PackedInt32Array() # ticks until a matched cell vanishes, 0 = not clearing
var cursor_x := 2 # cursor covers cursor_x and cursor_x + 1
var cursor_y := 6
var prev_input := 0
var hold := 0
var rise := 0
var fall_t := 0
var unsettled := true # something moved; run gravity, then look for matches
var clearing := 0
var rng := 1
var score := 0
var lost := false


static func create(game_seed: int) -> SimBoard:
	var b := SimBoard.new()
	b.cells.resize(W * H)
	b.clear_t.resize(W * H)
	b.rng = (game_seed & 0xFFFFFFFF) | 1
	for y in range(H - 5, H):
		b._fill_row(y)
	return b


func copy() -> SimBoard:
	var b := SimBoard.new()
	b.cells = cells.duplicate()
	b.clear_t = clear_t.duplicate()
	b.cursor_x = cursor_x
	b.cursor_y = cursor_y
	b.prev_input = prev_input
	b.hold = hold
	b.rise = rise
	b.fall_t = fall_t
	b.unsettled = unsettled
	b.clearing = clearing
	b.rng = rng
	b.score = score
	b.lost = lost
	return b


func checksum() -> int:
	return hash([cells, clear_t, cursor_x, cursor_y, prev_input, hold, rise, fall_t,
			unsettled, clearing, rng, score, lost])


func step(input: int) -> void:
	if lost:
		return
	var pressed := input & ~prev_input
	var dir := input & SimConst.DIRS
	if dir != 0 and dir == prev_input & SimConst.DIRS:
		hold += 1
		if hold >= SimConst.REPEAT_DELAY and (hold - SimConst.REPEAT_DELAY) % SimConst.REPEAT_RATE == 0:
			_move(dir)
	else:
		hold = 0
		if dir != 0:
			_move(dir)
	prev_input = input

	if pressed & SimConst.SWAP:
		_swap()
	if clearing > 0:
		_tick_clears()

	fall_t += 1
	if fall_t >= SimConst.FALL_TICKS:
		fall_t = 0
		if unsettled and not _gravity_step():
			unsettled = false
			_scan_matches()

	if clearing == 0 and not unsettled:
		rise += SimConst.RAISE_SPEED if input & SimConst.RAISE else 1
		if rise >= SimConst.ROW_UNITS:
			rise -= SimConst.ROW_UNITS
			_push_row()


func _move(dir: int) -> void:
	if dir & SimConst.UP:
		cursor_y = maxi(cursor_y - 1, 0)
	if dir & SimConst.DOWN:
		cursor_y = mini(cursor_y + 1, H - 1)
	if dir & SimConst.LEFT:
		cursor_x = maxi(cursor_x - 1, 0)
	if dir & SimConst.RIGHT:
		cursor_x = mini(cursor_x + 1, W - 2)


func _swap() -> void:
	var i := cursor_y * W + cursor_x
	if (cells[i] | cells[i + 1]) == 0 or clear_t[i] or clear_t[i + 1]:
		return
	var c := cells[i]
	cells[i] = cells[i + 1]
	cells[i + 1] = c
	unsettled = true


func _tick_clears() -> void:
	for i in W * H:
		if clear_t[i] > 0:
			clear_t[i] -= 1
			if clear_t[i] == 0:
				cells[i] = 0
				clearing -= 1
				unsettled = true


## Drops every unsupported block one cell. Returns whether anything moved.
func _gravity_step() -> bool:
	var moved := false
	for y in range(H - 2, -1, -1):
		for x in W:
			var i := y * W + x
			if cells[i] != 0 and clear_t[i] == 0 and cells[i + W] == 0:
				cells[i + W] = cells[i]
				cells[i] = 0
				moved = true
	return moved


func _matchable(i: int) -> bool:
	return cells[i] != 0 and clear_t[i] == 0


func _scan_matches() -> void:
	var mark := PackedByteArray()
	mark.resize(W * H)
	for y in H:
		var run := 1
		for x in range(1, W + 1):
			var i := y * W + x
			if x < W and _matchable(i) and _matchable(i - 1) and cells[i] == cells[i - 1]:
				run += 1
			else:
				if run >= 3:
					for k in run:
						mark[i - 1 - k] = 1
				run = 1
	for x in W:
		var run := 1
		for y in range(1, H + 1):
			var i := y * W + x
			if y < H and _matchable(i) and _matchable(i - W) and cells[i] == cells[i - W]:
				run += 1
			else:
				if run >= 3:
					for k in run:
						mark[i - W - k * W] = 1
				run = 1
	var n := 0
	for i in W * H:
		if mark[i]:
			clear_t[i] = SimConst.CLEAR_TICKS
			n += 1
	clearing += n
	score += n * 10 + maxi(n - 3, 0) * 20


func _push_row() -> void:
	for x in W:
		if cells[x] != 0:
			lost = true
			return
	cells = cells.slice(W)
	cells.resize(W * H)
	clear_t = clear_t.slice(W)
	clear_t.resize(W * H)
	_fill_row(H - 1)
	cursor_y = maxi(cursor_y - 1, 0)
	unsettled = true


## Random row with no horizontal or vertical triples against the rows above.
func _fill_row(y: int) -> void:
	for x in W:
		var i := y * W + x
		var c := 0
		while true:
			c = _rand() % SimConst.COLORS + 1
			var h := x >= 2 and cells[i - 1] == c and cells[i - 2] == c
			var v := y >= 2 and cells[i - W] == c and cells[i - 2 * W] == c
			if not (h or v):
				break
		cells[i] = c


func _rand() -> int: # xorshift32, kept in the low 32 bits of a 64-bit int
	var x := rng
	x ^= (x << 13) & 0xFFFFFFFF
	x ^= x >> 17
	x ^= (x << 5) & 0xFFFFFFFF
	rng = x
	return x
