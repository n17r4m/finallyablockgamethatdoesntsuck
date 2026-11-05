extends SceneTree
## Regenerates tests/golden: the recorded games that lock the rules. Run this only when
## a rule change is intended, after bumping SimConst.RULES_VERSION.
##   godot --headless --path . -s tools/make_golden.gd
##
## Hand-built boards reach what random play rarely does (long chains, every combo size, each
## garbage shape). Each one checks that it really did what it's named for, so a corpus can't
## quietly stop testing something. CPU and chaos games cover what nobody thought to build.

const OUT := "res://tests/golden"
const TPF := SimConst.TICKS_PER_FRAME
const HZ := SimConst.TICK_HZ
const GO := SimConst.COUNTDOWN_TICKS
const BOTTOM := SimConst.H - 1 # visible row number of the floor, for SimConst.target

var _failed := 0
var _bytes := 0
var _count := 0


## A game being played live, logged as a replay is: only changes, per tick.
class Rec:
	var state: SimState
	var game_seed: int
	var solo: bool
	var ops: Array
	var ticks: Array = [PackedInt64Array(), PackedInt64Array()]
	var masks: Array = [PackedInt32Array(), PackedInt32Array()]
	var last := [0, 0]

	func _init(seed_value: int, ops_list := [], solo_mode := false) -> void:
		game_seed = seed_value
		solo = solo_mode
		ops = ops_list
		state = SimState.create(seed_value, solo_mode)
		Replay.apply_setup(state, ops_list)

	func run(n: int, m0 := 0, m1 := 0) -> void:
		for _i in n:
			_log(0, m0)
			_log(1, m1)
			state.step(m0, m1)

	func _log(p: int, m: int) -> void:
		if m != last[p]:
			last[p] = m
			ticks[p].append(state.tick)
			masks[p].append(m)

	func to_replay() -> Replay:
		return Replay.build(game_seed, solo, ops, ticks, masks, state.tick)


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	for f in DirAccess.get_files_at(OUT):
		if f.ends_with(".fbgr") or f == "vectors.json":
			DirAccess.remove_absolute("%s/%s" % [OUT, f])
	_combos()
	_chains()
	_garbage()
	_endings()
	_controls()
	_chaos()
	_cpu_games()
	_vectors()
	print("%d replays, %d bytes" % [_count, _bytes])
	print("PASS" if _failed == 0 else "FAIL (%d)" % _failed)
	quit(0 if _failed == 0 else 1)


func _check(ok: bool, what: String) -> void:
	if not ok:
		_failed += 1
		print("  FAIL " + what)


func _save(name: String, r: Replay) -> void:
	var bytes := r.encode()
	var f := FileAccess.open("%s/%s.fbgr" % [OUT, name], FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	_bytes += bytes.size()
	_count += 1
	var err := Replay.decode(bytes).verify()
	_check(err == "", "%s doesn't verify: %s" % [name, err])


func _clear_both() -> Array:
	return [[Replay.OP_CLEAR, 0], [Replay.OP_CLEAR, 1]]


func _put(ops: Array, x: int, row: int, c: int) -> void:
	ops.append([Replay.OP_PUT, 0, x, row, c])


# --- combos -------------------------------------------------------------------

## An L: a row along the floor and a column up the left, sharing the corner.
func _combos() -> void:
	for n in range(3, 15):
		var ops := _clear_both()
		var across := mini(6, n if n <= 6 else n - 2)
		var up := 0 if n <= 6 else n - across + 1
		for x in across:
			_put(ops, x, 0, 1)
		for row in range(1, up):
			_put(ops, 0, row, 1)
		var rec := Rec.new(100 + n, ops)
		rec.run(GO + HZ * 8)
		var b := rec.state.boards[0]
		_check(n == 3 or b.fx_combo == n, "combo_%d made a combo of %d" % [n, b.fx_combo])
		_save("combo_%02d" % n, rec.to_replay())


# --- chains -------------------------------------------------------------------

## A nested column: pairs below, three to clear, singles above. Each clear drops the next
## single onto its pair, so every link is exactly one match: D D C C A A A C D.
func _chains() -> void:
	var colours := [2, 3, 4, 5]
	for chain in range(2, 9):
		var ops := _clear_both()
		var links := chain - 1
		var stack: Array[int] = []
		for i in range(links - 1, -1, -1):
			stack.append(colours[i % 4])
			stack.append(colours[i % 4])
		stack.append_array([1, 1, 1])
		for i in links:
			stack.append(colours[i % 4])
		for row in stack.size():
			_put(ops, 0, row, stack[row])
		var rec := Rec.new(200 + chain, ops)
		var b := rec.state.boards[0]
		rec.run(GO + TPF)
		var waited := 0
		while b.chain_n > 1 or waited < HZ * 2:
			rec.run(TPF)
			waited += TPF
			if waited > HZ * 60:
				break
		rec.run(HZ * 6) # long enough for the chain's garbage to land on the other side
		_check(b.best_chain == chain, "chain_%d reached %d" % [chain, b.best_chain])
		_save("chain_%d" % chain, rec.to_replay())


# --- garbage ------------------------------------------------------------------

## A slab lands on a floor of panels, then a swap under it completes a match and cracks it.
func _garbage() -> void:
	var shapes := [[3, 1], [4, 1], [5, 1], [6, 1], [6, 2], [6, 4], [6, 8], [6, 12]]
	for shape: Array in shapes:
		_crack("garbage_%dx%d" % shape, [shape], 300 + shape[0] * 13 + shape[1])
	# Two slabs side by side: the match touches one, and the crack spreads through the other.
	_crack("garbage_linked", [[3, 1], [3, 1]], 390)
	# One on top of another.
	_crack("garbage_stacked", [[6, 1], [6, 2]], 391)
	# One matched panel touches a slab above it and another beside it, so the order it looks
	# around in decides which slab rolls its colours first.
	_crack("garbage_two_sided", [[3, 1], [3, 1]], 392, [[1, 2, 1, 3, 4, 3], [3, 4, 1, 4, 3, 4], [4, 1, 2]], 2)


## The default floor: swapping columns 2 and 3 makes 1 1 1. A floor with swap_row set swaps
## columns 1 and 2 of that row instead.
func _crack(name: String, slabs: Array, game_seed: int, floor_rows := [[1, 1, 2, 1, 3, 4]], swap_row := 0) -> void:
	var ops := _clear_both()
	for row in floor_rows.size():
		for x in floor_rows[row].size():
			_put(ops, x, row, floor_rows[row][x])
	for s: Array in slabs:
		ops.append([Replay.OP_GARBAGE, 0, s[0], s[1]])
	var rec := Rec.new(game_seed, ops)
	var b := rec.state.boards[0]
	rec.run(GO)
	var waited := 0
	while waited < HZ * 20 and not (b.gar_q.is_empty() and _all_slabs_rest(b)):
		rec.run(TPF)
		waited += TPF
	_check(b.next_gid - 1 == slabs.size(), "%s: only %d slabs landed" % [name, b.next_gid - 1])
	var cursor := SimConst.target(1 if swap_row > 0 else 2, BOTTOM - swap_row)
	rec.run(TPF, cursor | SimConst.SWAP)
	rec.run(TPF, cursor)
	var cracked := false
	var bullet := false
	var at := 0
	while at < HZ * 25:
		rec.run(TPF)
		at += TPF
		cracked = cracked or _any_slab_matched(b)
		bullet = bullet or b.time_rate < SimConst.TIME_UNIT
		if cracked and at > HZ * 2 and not _any_slab_matched(b) and b.time_rate == SimConst.TIME_UNIT and _settled(b):
			break
	_check(cracked, "%s never cracked" % name)
	_check(bullet, "%s never reached bullet time" % name)
	rec.run(HZ * 3)
	_save(name, rec.to_replay())


func _all_slabs_rest(b: SimBoard) -> bool:
	var seen := false
	for i in SimBoard.N:
		if b.gid[i] != 0:
			seen = true
			if b.st[i] != SimBoard.NORMAL:
				return false
	return seen


func _any_slab_matched(b: SimBoard) -> bool:
	for i in SimBoard.N:
		if b.gid[i] != 0 and b.st[i] == SimBoard.MATCHED:
			return true
	return false


func _settled(b: SimBoard) -> bool:
	if b.chain_n != 1:
		return false
	for i in SimBoard.N:
		if b.color[i] != 0 and not b._resting(i):
			return false
	return true


# --- how games end --------------------------------------------------------------

func _endings() -> void:
	var cases := [["end_p0_tops_out", SimConst.RAISE, 0, 1], ["end_p1_tops_out", 0, SimConst.RAISE, 0], ["end_draw", SimConst.RAISE, SimConst.RAISE, 2]]
	for c: Array in cases:
		var rec := Rec.new(400)
		rec.run(GO)
		var waited := 0
		while rec.state.winner == -1 and waited < HZ * 300:
			rec.run(TPF, c[1], c[2])
			waited += TPF
		_check(rec.state.winner == c[3], "%s: winner %d" % [c[0], rec.state.winner])
		rec.run(HZ)
		_save(c[0], rec.to_replay())
	# Solo, untouched, until the rise alone ends it: covers the speed-up too.
	var rec := Rec.new(401, [], true)
	var waited := 0
	while not rec.state.boards[0].lost and waited < HZ * 300:
		rec.run(TPF)
		waited += TPF
	_check(rec.state.boards[0].lost, "end_solo never ended")
	rec.run(HZ)
	_save("end_solo", rec.to_replay())


# --- controls ---------------------------------------------------------------------

func _controls() -> void:
	var rec := Rec.new(500)
	# In the countdown the cursor moves and swap does nothing, even held through GO.
	rec.run(HZ, SimConst.LEFT)
	rec.run(HZ, SimConst.UP | SimConst.RIGHT)
	rec.run(GO - 2 * HZ, SimConst.SWAP)
	rec.run(HZ, SimConst.SWAP)
	# Auto-repeat into every wall, opposing directions, and tapping faster than it repeats.
	for dir: int in [SimConst.LEFT, SimConst.RIGHT, SimConst.UP, SimConst.DOWN, SimConst.LEFT | SimConst.RIGHT, SimConst.UP | SimConst.DOWN]:
		rec.run(HZ, dir)
		rec.run(TPF)
	for i in 40:
		rec.run(TPF * 2, SimConst.LEFT if i % 2 == 0 else SimConst.RIGHT)
		rec.run(TPF * 2)
	# Touch: placing the cursor by absolute cell, at each edge.
	for t: Array in [[0, 0], [4, 0], [0, 11], [4, 11], [2, 6]]:
		rec.run(TPF * 3, SimConst.target(t[0], t[1]))
		rec.run(TPF * 3, SimConst.target(t[0], t[1]) | SimConst.SWAP)
		rec.run(TPF * 3)
	# Raising, and letting go.
	rec.run(HZ, SimConst.RAISE)
	rec.run(HZ * 2)
	_save("controls", rec.to_replay())
	_key_repeat()


## Holds a direction for different lengths and lets go partway up the well. Holding into a
## wall would end in the same place at any repeat rate, so each one waits for a checkpoint
## to record where it stopped before going back down.
func _key_repeat() -> void:
	var rec := Rec.new(501, _clear_both())
	rec.run(GO)
	var start := SimConst.REPEAT_DELAY - SimConst.TICKS_PER_FRAME
	var stop := SimConst.REPEAT_DELAY + SimConst.REPEAT_RATE * 9
	var seen := {}
	for held in range(start, stop, SimConst.TICKS_PER_FRAME):
		rec.run(HZ, SimConst.DOWN) # back to the floor
		rec.run(HZ - rec.state.tick % HZ)
		rec.run(held, SimConst.UP)
		rec.run(HZ - rec.state.tick % HZ)
		seen[rec.state.boards[0].cursor_y] = true
	_check(seen.size() >= 8, "key_repeat only stopped on %d different rows" % seen.size())
	_save("key_repeat", rec.to_replay())


# --- random play --------------------------------------------------------------------

## Engine-free LCG, so a rebuilt corpus doesn't depend on the engine's RNG.
func _lcg(x: int) -> int:
	return (x * 1103515245 + 12345) & 0x7FFFFFFF


func _chaos_mask(x: int) -> int:
	var m := SimConst.target((x >> 8) % (SimConst.W - 1), (x >> 12) % SimConst.H)
	if x & 192 == 192:
		m |= SimConst.SWAP
	if x & 0x700 == 0:
		m |= SimConst.RAISE
	return m


func _chaos() -> void:
	# Inputs on frame boundaries, as they arrive now...
	for sd in range(1, 5):
		_chaos_game("chaos_frame_%d" % sd, 600 + sd, sd, false)
	# ...and on any tick, as finer input timestamps will.
	for sd in range(5, 7):
		_chaos_game("chaos_subframe_%d" % sd, 600 + sd, sd, true)


func _chaos_game(name: String, game_seed: int, sd: int, subframe: bool) -> void:
	var x := sd * 2654435761 + 1
	var rec := Rec.new(game_seed)
	var m0 := 0
	var m1 := 0
	while rec.state.tick < HZ * 120 and rec.state.winner == -1:
		x = _lcg(x)
		m0 = _chaos_mask(x)
		x = _lcg(x)
		m1 = _chaos_mask(x)
		x = _lcg(x)
		rec.run((x >> 8) % 23 + 1 if subframe else TPF, m0, m1)
	rec.run(HZ)
	_save(name, rec.to_replay())


func _cpu_games() -> void:
	var games := [["Overmind", "hard", "Architect", "hard"], ["Blitz", "hard", "Overmind", "normal"], ["Architect", "max", "Blitz", "easy"], ["Overmind", "easy", "Overmind", "easy"]]
	var n := 0
	for g: Array in games:
		n += 1
		_cpu_game("cpu_%d" % n, g, 700 + n, 700 + n, 800 + n)
	# Chosen by search: a matched panel with a slab directly above and another directly below,
	# which is too hard to build by hand. It locks the order a panel looks around in.
	_cpu_game("cpu_slabs_above_and_below", ["Overmind", "hard", "Architect", "hard"], 1275, 1275, 1276)


func _cpu_game(name: String, g: Array, game_seed: int, seed0: int, seed1: int) -> void:
	var rec := Rec.new(game_seed)
	var c0 := CpuPlayer.opponent(g[0], g[1], seed0)
	var c1 := CpuPlayer.opponent(g[2], g[3], seed1)
	while rec.state.winner == -1 and rec.state.tick < HZ * 240:
		var i0 := c0.next_input(rec.state.boards[0])
		var i1 := c1.next_input(rec.state.boards[1])
		rec.run(TPF, i0, i1)
	rec.run(HZ)
	_save(name, rec.to_replay())


# --- hash test vectors ----------------------------------------------------------------

## The exact bytes behind a few hashes, so another implementation can debug its serializer
## field by field, without needing a working sim first.
func _vectors() -> void:
	var out := []
	for spec: Array in [["chain_4", 0], ["chain_4", GO + HZ], ["garbage_6x2", GO + HZ * 2 + 360]]:
		var bytes := FileAccess.get_file_as_bytes("%s/%s.fbgr" % [OUT, spec[0]])
		var r := Replay.decode(bytes)
		var want: int = spec[1]
		var hit := []
		if want == 0:
			hit.append(r.new_state())
		else:
			r.verify(func(s: SimState) -> void:
				if s.tick == want:
					hit.append(s.copy()))
		_check(hit.size() == 1, "vector for %s at tick %d never happened" % spec)
		if hit.size() == 1:
			var c: PackedByteArray = hit[0].canonical_bytes()
			var h := PackedByteArray()
			h.resize(8)
			h.encode_s64(0, SimConst.hash64(c))
			out.append({"replay": spec[0], "tick": want, "bytes": c.hex_encode(), "hash": h.hex_encode()})
	var f := FileAccess.open("%s/vectors.json" % OUT, FileAccess.WRITE)
	f.store_string(JSON.stringify(out, " "))
	f.close()
