class_name SimBoard
extends RefCounted
## One player's well: Panel de Pon rules on an integer grid.
##
## Every cell runs a small state machine (swap / hover / fall / land / matched)
## driven by tick timers. Nothing here is spatial beyond grid indices: sliding,
## falling, swap depth and pops are derived from these timers by BoardView.
## Steps 1080x/s and is re-simulated during rollback, so keep it lean.

const W := SimConst.W
const ROWS := SimConst.ROWS
const TOP := SimConst.BUF # first visible row
const N := W * ROWS

enum { NORMAL, SWAP_L, SWAP_R, HOVER, FALL, LAND, MATCHED }

## Every field that is game state. copy() and checksum() walk this list, so a
## field missing here silently breaks rollback — new state goes here.
const STATE := ["color", "st", "tm", "aux", "chain", "gid", "reveal", "next_row",
	"cursor_x", "cursor_y", "prev_input", "hold", "rise", "stop_t", "health", "rng", "score", "lost",
	"busy", "need_scan", "need_support", "has_matched", "chain_n",
	"outbox", "gar_q", "gar_t", "gar_side", "next_gid", "fx_combo", "fx_chain", "fx_t",
	"age", "sent", "best_chain", "swaps"]

# Per cell, row-major, y = 0 is the top of the hidden buffer.
var color := PackedByteArray() # 0 empty, 1..COLORS panel, GARBAGE
var st := PackedByteArray() # state enum
var tm := PackedInt32Array() # ticks left in the current state
var aux := PackedInt32Array() # MATCHED: pop tick | flash-end tick << 16
var chain := PackedByteArray() # 1 = falling because something under it cleared
var gid := PackedInt32Array() # garbage slab id, 0 = panel
var reveal := PackedByteArray() # cracking garbage: the panel colour this cell becomes (fixed at crack start)
var next_row := PackedByteArray() # rising in from below

var cursor_x := 2 # cursor covers cursor_x and cursor_x + 1
var cursor_y := TOP + 6
var prev_input := 0
var hold := 0
var rise := 0
var stop_t := 0
var health := SimConst.HEALTH_TICKS # drains while topped out; 0 = lost
var rng := 1
var score := 0
var lost := false

var busy := false # some cell is not NORMAL; run the per-cell update
var need_scan := false # a panel came to rest; look for matches
var need_support := false # a cell emptied; look for unsupported blocks
var has_matched := false
var chain_n := 1 # current chain length; 1 = no chain

var outbox := PackedInt32Array() # slabs sent this tick; SimState delivers them
var gar_q := PackedInt32Array() # incoming slabs, head drops first
var gar_t := 0
var gar_side := 0 # alternate narrow slabs left/right
var next_gid := 1

var fx_combo := 0 # latest callouts for presentation
var fx_chain := 0
var fx_t := 0

var age := 0 # live ticks; drives the rise speed-up
var sent := 0 # garbage cells sent (stats)
var best_chain := 1 # (stats)
var swaps := 0 # (stats)


static func create(game_seed: int) -> SimBoard:
	var b := SimBoard.new()
	b.color.resize(N)
	b.st.resize(N)
	b.tm.resize(N)
	b.aux.resize(N)
	b.chain.resize(N)
	b.gid.resize(N)
	b.reveal.resize(N)
	b.rng = (game_seed & 0xFFFFFFFF) | 1
	for y in range(ROWS - 5, ROWS):
		var row := b._make_row(y - 1)
		for x in W:
			b.color[y * W + x] = row[x]
	b.next_row = b._make_row(ROWS - 1)
	return b


func copy() -> SimBoard:
	var b := SimBoard.new()
	for f: String in STATE:
		var v: Variant = get(f)
		b.set(f, v.duplicate() if typeof(v) >= TYPE_PACKED_BYTE_ARRAY else v)
	return b


func checksum() -> int:
	var vals := []
	for f: String in STATE:
		vals.append(get(f))
	return hash(vals)


## live = false during the countdown: the cursor moves, nothing else happens.
func step(input: int, live := true) -> void:
	if lost:
		return
	if not live:
		_handle_input(input & SimConst.DIRS)
		return
	age += 1
	_handle_input(input)
	if busy:
		_update_cells()
	else:
		has_matched = false
	if need_support:
		_apply_support()
	if need_scan:
		_scan()
	if chain_n > 1:
		_check_chain_end()
	_feed_garbage()
	_rise(input)
	if fx_t > 0:
		fx_t -= 1


func receive_garbage(slabs: PackedInt32Array) -> void:
	if gar_q.is_empty():
		gar_t = SimConst.GARBAGE_DELAY
	gar_q.append_array(slabs)


## Test/puzzle helper: place a resting panel; row 0 is the bottom visible row.
func put(x: int, row: int, c: int) -> void:
	var i := (ROWS - 1 - row) * W + x
	_clear_cell(i)
	color[i] = c
	need_scan = true
	need_support = true


func clear_all() -> void:
	for i in N:
		_clear_cell(i)


# --- input ------------------------------------------------------------------

func _handle_input(input: int) -> void:
	var pressed := input & ~prev_input
	var dir := input & SimConst.DIRS
	if dir != 0 and dir == prev_input & SimConst.DIRS:
		hold += 1
		if hold >= SimConst.REPEAT_DELAY and (hold - SimConst.REPEAT_DELAY) % SimConst.REPEAT_RATE == 0:
			_move_cursor(dir)
	else:
		hold = 0
		if dir != 0:
			_move_cursor(dir)
	prev_input = input
	if pressed & SimConst.SWAP:
		_try_swap()


func _move_cursor(dir: int) -> void:
	if dir & SimConst.UP:
		cursor_y = maxi(cursor_y - 1, TOP)
	if dir & SimConst.DOWN:
		cursor_y = mini(cursor_y + 1, ROWS - 1)
	if dir & SimConst.LEFT:
		cursor_x = maxi(cursor_x - 1, 0)
	if dir & SimConst.RIGHT:
		cursor_x = mini(cursor_x + 1, W - 2)


func _try_swap() -> void:
	var i := cursor_y * W + cursor_x
	var j := i + 1
	if color[i] == 0 and color[j] == 0:
		return
	for k: int in [i, j]:
		if color[k] != 0 and (gid[k] != 0 or not _resting(k)):
			return
		# Don't slide into a gap something is about to fall into.
		if color[k] == 0 and k >= W and color[k - W] != 0 and (st[k - W] == HOVER or st[k - W] == FALL):
			return
	var c := color[i]
	color[i] = color[j]
	color[j] = c
	swaps += 1
	for k: int in [i, j]:
		st[k] = NORMAL
		tm[k] = 0
		chain[k] = 0
	if color[j] != 0:
		_set_state(j, SWAP_R, SimConst.SWAP_TICKS) # arrived from the left
	if color[i] != 0:
		_set_state(i, SWAP_L, SimConst.SWAP_TICKS) # arrived from the right


# --- per-cell update ----------------------------------------------------------

func _update_cells() -> void:
	busy = false
	has_matched = false
	var done := PackedInt32Array() # slabs already handled this tick
	for y in range(ROWS - 1, -1, -1): # bottom-up so columns move together
		for x in W:
			var i := y * W + x
			if color[i] == 0 or st[i] == NORMAL:
				continue
			busy = true
			if gid[i] != 0:
				if not done.has(gid[i]):
					done.append(gid[i])
					_update_slab(i) # first hit is the slab's bottom-left cell
				continue
			match st[i]:
				SWAP_L, SWAP_R:
					tm[i] -= 1
					if tm[i] == 0:
						st[i] = NORMAL
						need_scan = true
						need_support = true
				LAND:
					tm[i] -= 1
					if tm[i] == 0:
						st[i] = NORMAL
				HOVER:
					tm[i] -= 1
					if tm[i] == 0:
						st[i] = FALL
						tm[i] = SimConst.FALL_TICKS
				FALL:
					_fall(i)
				MATCHED:
					has_matched = true
					tm[i] -= 1
					if tm[i] == 0:
						_vanish(i)


func _fall(i: int) -> void:
	var b := i + W
	if b < N and color[b] == 0:
		tm[i] -= 1
		if tm[i] <= 0:
			_move(i, b)
			tm[b] = SimConst.FALL_TICKS
	elif b < N and (st[b] == FALL or st[b] == HOVER):
		tm[i] = maxi(tm[i] - 1, 1) # follow the block below as soon as it moves
	else:
		st[i] = LAND
		tm[i] = SimConst.LAND_TICKS
		need_scan = true


## A matched panel disappears; everything stacked on it becomes chain material.
func _vanish(i: int) -> void:
	_clear_cell(i)
	var j := i - W
	while j >= 0 and color[j] != 0 and gid[j] == 0 and _resting(j):
		chain[j] = 1
		j -= W
	need_support = true


func _update_slab(i: int) -> void:
	var r := _slab_rect(i)
	var x0 := r[0]
	var y0 := r[1]
	var w := r[2]
	var h := r[3]
	var y1 := y0 + h - 1
	match st[i]:
		HOVER:
			if _slab_tick(r) == 0:
				_slab_set(r, FALL, SimConst.FALL_TICKS)
		FALL:
			var rest := y1 + 1 >= ROWS
			var moving := false
			if not rest:
				for k in w:
					var c := (y1 + 1) * W + x0 + k
					if color[c] != 0:
						if st[c] == FALL or st[c] == HOVER:
							moving = true
						else:
							rest = true
			if rest:
				_slab_set(r, NORMAL, 0)
			elif moving:
				_slab_set(r, FALL, maxi(tm[i] - 1, 1))
			elif _slab_tick(r) <= 0:
				for y in range(y1, y0 - 1, -1):
					for k in w:
						_move(y * W + x0 + k, (y + 1) * W + x0 + k)
				_slab_set(PackedInt32Array([x0, y0 + 1, w, h]), FALL, SimConst.FALL_TICKS)
		MATCHED:
			has_matched = true
			if _slab_tick(r) == 0:
				# Bottom row becomes the panels revealed during the crack (they may chain);
				# the rest shrinks back to garbage. Unsupported ones hover, then fall.
				for k in w:
					var c := y1 * W + x0 + k
					var col := reveal[c]
					_clear_cell(c)
					color[c] = col if col != 0 else _rand() % SimConst.COLORS + 1
					chain[c] = 1
					var below := c + W
					if below < N and (color[below] == 0 or st[below] == HOVER or st[below] == FALL):
						_set_state(c, HOVER, SimConst.GARBAGE_HANG_TICKS) # bullet time before the drop
				if h > 1:
					_slab_set(PackedInt32Array([x0, y0, w, h - 1]), NORMAL, 0)
				need_scan = true
				need_support = true


# --- support / gravity ---------------------------------------------------------

func _apply_support() -> void:
	need_support = false
	var done := PackedInt32Array()
	for y in range(ROWS - 1, -1, -1):
		for x in W:
			var i := y * W + x
			if color[i] == 0:
				continue
			if gid[i] != 0:
				if not done.has(gid[i]):
					done.append(gid[i])
					_support_slab(i)
				continue
			var b := i + W
			if b >= N or not _resting(i):
				continue
			if color[b] == 0:
				_set_state(i, HOVER, SimConst.HOVER_TICKS)
			elif st[b] == HOVER or st[b] == FALL:
				_set_state(i, st[b], tm[b]) # join the column below so it moves as one


func _support_slab(i: int) -> void:
	if st[i] != NORMAL:
		return
	var r := _slab_rect(i)
	var below := (r[1] + r[3]) * W + r[0]
	if below >= N:
		return
	var join := -1
	for k in r[2]:
		var c := below + k
		if color[c] == 0:
			continue
		if st[c] == HOVER or st[c] == FALL:
			join = c
		else:
			return # resting on something
	if join < 0:
		_slab_set(r, HOVER, SimConst.HOVER_TICKS)
	else:
		_slab_set(r, st[join], tm[join])


# --- matching -----------------------------------------------------------------

func _scan() -> void:
	need_scan = false
	var mark := PackedByteArray()
	mark.resize(N)
	for y in ROWS:
		var run := 1
		for x in range(1, W + 1):
			var i := y * W + x
			if x < W and _matchable(i) and _matchable(i - 1) and color[i] == color[i - 1]:
				run += 1
			else:
				if run >= 3:
					for k in run:
						mark[i - 1 - k] = 1
				run = 1
	for x in W:
		var run := 1
		for y in range(1, ROWS + 1):
			var i := y * W + x
			if y < ROWS and _matchable(i) and _matchable(i - W) and color[i] == color[i - W]:
				run += 1
			else:
				if run >= 3:
					for k in run:
						mark[i - W - k * W] = 1
				run = 1

	var idx := PackedInt32Array()
	var chained := false
	for i in N:
		if mark[i]:
			idx.append(i)
			chained = chained or chain[i] == 1
	var n := idx.size()
	if n > 0:
		var pops := SimConst.POP_TICKS * n
		var total := SimConst.FLASH_TICKS + pops
		for k in n:
			_set_state(idx[k], MATCHED, total)
			aux[idx[k]] = SimConst.POP_TICKS * (n - 1 - k) | (pops << 16)
			chain[idx[k]] = 0
		has_matched = true
		score += n * 10
		if n >= 4:
			for w: int in SimConst.COMBO_GARBAGE.get(n, [6, 6, 6]):
				outbox.append(SimConst.slab(w, 1))
				sent += w
			fx_combo = n
			score += (n - 3) * 20
		if chained:
			chain_n += 1
			fx_chain = chain_n
			best_chain = maxi(best_chain, chain_n)
			score += 50 * (chain_n - 1)
		if n >= 4 or chained:
			stop_t = maxi(stop_t, SimConst.STOP_TICKS)
			fx_t = SimConst.FX_TICKS
		_convert_touching(idx, total)
	# Anything that came to rest without matching is no longer part of a chain.
	for i in N:
		if chain[i] and _resting(i):
			chain[i] = 0


## Garbage touching a match (and garbage touching that, transitively) starts cracking.
## It breaks apart in a ripple from where the match touched it: each cell's turn
## comes by its distance through the garbage from the matched panels, bottom row
## first on ties. Cells that will become panels reveal slowly; the rest pop fast.
func _convert_touching(matched: PackedInt32Array, total: int) -> void:
	# Which slabs crack: everything reachable from the match through touching garbage.
	var todo := matched.duplicate()
	var seen := PackedInt32Array()
	while not todo.is_empty():
		var i := todo[-1]
		todo.remove_at(todo.size() - 1)
		for j in _neighbours(i):
			if gid[j] == 0 or seen.has(gid[j]) or st[j] != NORMAL:
				continue
			seen.append(gid[j])
			var r := _slab_rect(j)
			for y in range(r[1], r[1] + r[3]):
				for k in r[2]:
					todo.append(y * W + r[0] + k)
			# Decide now what the bottom row will become, so it can be revealed cell by cell.
			for k in r[2]:
				reveal[(r[1] + r[3] - 1) * W + r[0] + k] = _rand() % SimConst.COLORS + 1
	if seen.is_empty():
		return
	# Ripple: breadth-first distance from the matched panels through cracking cells.
	var dist := PackedInt32Array()
	dist.resize(N)
	dist.fill(-1)
	var queue := PackedInt32Array()
	for i in matched:
		for j in _neighbours(i):
			if gid[j] != 0 and seen.has(gid[j]) and dist[j] < 0:
				dist[j] = 1
				queue.append(j)
	var head := 0
	while head < queue.size():
		var i := queue[head]
		head += 1
		for j in _neighbours(i):
			if gid[j] != 0 and seen.has(gid[j]) and dist[j] < 0:
				dist[j] = dist[i] + 1
				queue.append(j)
	# Order by distance, then lower rows first, then left to right. Encoded as one sort key.
	var keys := PackedInt64Array()
	for i in queue:
		keys.append((dist[i] << 40) | ((ROWS - 1 - i / W) << 32) | ((i % W) << 24) | i)
	keys.sort()
	var cells := PackedInt32Array()
	var durs := PackedInt32Array()
	var pops := 0
	for key in keys:
		var i := key & 0xFFFFFF
		cells.append(i)
		var d := SimConst.REVEAL_TICKS if reveal[i] != 0 else SimConst.SHELL_POP_TICKS
		durs.append(d)
		pops += d
	var elapsed := 0
	for k in cells.size():
		elapsed += durs[k]
		_set_state(cells[k], MATCHED, total + pops)
		aux[cells[k]] = (pops - elapsed) | (pops << 16)


func _neighbours(i: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var x := i % W
	if i >= W:
		out.append(i - W)
	if i + W < N:
		out.append(i + W)
	if x > 0:
		out.append(i - 1)
	if x < W - 1:
		out.append(i + 1)
	return out


func _check_chain_end() -> void:
	for i in N:
		if chain[i] or (st[i] == MATCHED and gid[i] == 0):
			return
	outbox.append(SimConst.slab(W, mini(chain_n - 1, SimConst.BUF)))
	sent += W * mini(chain_n - 1, SimConst.BUF)
	chain_n = 1


# --- garbage in, rise ---------------------------------------------------------

func _feed_garbage() -> void:
	if gar_q.is_empty():
		return
	if gar_t > 0:
		gar_t -= 1
	elif not has_matched and chain_n == 1 and _drop_garbage(gar_q[0]):
		gar_q.remove_at(0)
		gar_t = SimConst.GARBAGE_GAP


## Spawns a slab at the top of the hidden buffer. Waits while that spot is occupied.
func _drop_garbage(slab: int) -> bool:
	var w := slab % 8
	var h := slab / 8
	var x0 := 0 if gar_side == 0 else W - w
	for y in h:
		for x in range(x0, x0 + w):
			if color[y * W + x] != 0:
				return false
	for y in h:
		for x in range(x0, x0 + w):
			var c := y * W + x
			color[c] = SimConst.GARBAGE
			gid[c] = next_gid
			_set_state(c, FALL, SimConst.FALL_TICKS)
	next_gid += 1
	gar_side ^= 1
	return true


func _rise(input: int) -> void:
	if has_matched:
		return
	if topped():
		# Pressed against the top: the stack can't rise, grace drains instead.
		if stop_t > 0:
			stop_t -= 1
		else:
			health -= 1
			lost = health <= 0
		return
	health = SimConst.HEALTH_TICKS
	if input & SimConst.RAISE:
		stop_t = 0
		rise += SimConst.RAISE_SPEED
	elif stop_t > 0:
		stop_t -= 1
		return
	else:
		rise += 1 + age / SimConst.SPEEDUP_TICKS
	if rise >= SimConst.ROW_UNITS:
		rise = rise - SimConst.ROW_UNITS if _push_row() else SimConst.ROW_UNITS


func _push_row() -> bool:
	for x in W:
		if color[x] != 0:
			return false # buffer is full to the brim; hold the stack until it drains
	color = color.slice(W)
	color.resize(N)
	st = st.slice(W)
	st.resize(N)
	tm = tm.slice(W)
	tm.resize(N)
	aux = aux.slice(W)
	aux.resize(N)
	chain = chain.slice(W)
	chain.resize(N)
	gid = gid.slice(W)
	gid.resize(N)
	reveal = reveal.slice(W)
	reveal.resize(N)
	for x in W:
		color[(ROWS - 1) * W + x] = next_row[x]
	next_row = _make_row(ROWS - 1)
	cursor_y = maxi(cursor_y - 1, TOP)
	need_scan = true
	return true


# --- helpers ------------------------------------------------------------------

## Something is resting in the top visible row.
func topped() -> bool:
	for x in W:
		var i := TOP * W + x
		if color[i] != 0 and st[i] != FALL and st[i] != HOVER:
			return true
	return false


func _resting(i: int) -> bool:
	return st[i] == NORMAL or st[i] == LAND


func _matchable(i: int) -> bool:
	return color[i] != 0 and color[i] <= SimConst.COLORS and _resting(i)


func _set_state(i: int, s: int, t: int) -> void:
	st[i] = s
	tm[i] = t
	busy = true


func _clear_cell(i: int) -> void:
	color[i] = 0
	st[i] = NORMAL
	tm[i] = 0
	aux[i] = 0
	chain[i] = 0
	gid[i] = 0
	reveal[i] = 0


func _move(from: int, to: int) -> void:
	color[to] = color[from]
	st[to] = st[from]
	tm[to] = tm[from]
	aux[to] = aux[from]
	chain[to] = chain[from]
	gid[to] = gid[from]
	reveal[to] = reveal[from]
	_clear_cell(from)


## [x0, y0, w, h] of the (rectangular) slab containing cell i.
func _slab_rect(i: int) -> PackedInt32Array:
	var g := gid[i]
	var x0 := i % W
	var y0 := i / W
	while x0 > 0 and gid[y0 * W + x0 - 1] == g:
		x0 -= 1
	while y0 > 0 and gid[(y0 - 1) * W + x0] == g:
		y0 -= 1
	var w := 1
	while x0 + w < W and gid[y0 * W + x0 + w] == g:
		w += 1
	var h := 1
	while y0 + h < ROWS and gid[(y0 + h) * W + x0] == g:
		h += 1
	return PackedInt32Array([x0, y0, w, h])


func _slab_set(r: PackedInt32Array, s: int, t: int) -> void:
	for y in range(r[1], r[1] + r[3]):
		for k in r[2]:
			_set_state(y * W + r[0] + k, s, t)


## Decrements every cell's timer in the slab; returns the new value.
func _slab_tick(r: PackedInt32Array) -> int:
	var t := 0
	for y in range(r[1], r[1] + r[3]):
		for k in r[2]:
			var c := y * W + r[0] + k
			tm[c] -= 1
			t = tm[c]
	return t


## A row of panels with no triples against itself or the two rows from `above` up.
func _make_row(above: int) -> PackedByteArray:
	var row := PackedByteArray()
	row.resize(W)
	for x in W:
		var c := 0
		while true:
			c = _rand() % SimConst.COLORS + 1
			var h := x >= 2 and row[x - 1] == c and row[x - 2] == c
			var v := above >= 1 and color[above * W + x] == c and color[(above - 1) * W + x] == c
			if not (h or v):
				break
		row[x] = c
	return row


func _rand() -> int: # xorshift32, kept in the low 32 bits of a 64-bit int
	var x := rng
	x ^= (x << 13) & 0xFFFFFFFF
	x ^= x >> 17
	x ^= (x << 5) & 0xFFFFFFFF
	rng = x
	return x
