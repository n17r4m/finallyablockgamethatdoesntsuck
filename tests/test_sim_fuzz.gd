extends SceneTree
## Chaos-fuzzes the sim against its invariants, and checks snapshots and P1/P2 fairness.
##   godot --headless --path . -s tests/test_sim_fuzz.gd [-- --minutes=3 --seed=1]
##
## Invariants are checked on live boards: broken cells, garbage slabs, panels left floating,
## missed matches and boards that never settle. Inputs are touch-style targeting, because
## that reaches far more states than walking a cursor. Garbage is injected directly.

const W := SimConst.W
const ROWS := SimConst.ROWS
const N := W * ROWS
const TICK_HZ := SimConst.TICK_HZ

var _viol := {}
var _cov := {}
var _raise_p := 0.05
var _failed := 0


func _init() -> void:
	var minutes := 3
	var sd := 1
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--minutes="):
			minutes = a.trim_prefix("--minutes=").to_int()
		elif a.begins_with("--seed="):
			sd = a.trim_prefix("--seed=").to_int()
	_check_state_list()
	_fuzz(sd, TICK_HZ * 60 * minutes)
	_mirror(sd, TICK_HZ * 60 * minutes)
	print("PASS" if _failed == 0 else "FAIL (%d)" % _failed)
	quit(0 if _failed == 0 else 1)


func _fail(what: String) -> void:
	_failed += 1
	print("  FAIL " + what)


## A var missing from SimBoard.STATE silently breaks rollback.
func _check_state_list() -> void:
	var b := SimBoard.new()
	for p in b.get_script().get_script_property_list():
		if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and not SimBoard.STATE.has(p.name):
			_fail("SimBoard.%s is missing from STATE" % p.name)


# --- invariants ---------------------------------------------------------------

func _v(name: String, tick: int, b: SimBoard) -> void:
	if not _viol.has(name):
		_viol[name] = {"n": 0, "tick": tick, "board": _ascii(b)}
	_viol[name].n += 1


## One row per line, each cell as colour/state/garbage id.
func _ascii(b: SimBoard) -> String:
	var out := ""
	for y in ROWS:
		for x in W:
			var i := y * W + x
			out += "%d/%d/%d " % [b.color[i], b.st[i], b.gid[i]]
		out += "\n"
	return out


func _inv(b: SimBoard, tick: int) -> void:
	var slabs := {}
	var swap_col := [false, false, false, false, false, false]
	for i in N:
		var c := b.color[i]
		var st := b.st[i]
		if st == SimBoard.SWAP_L or st == SimBoard.SWAP_R:
			swap_col[i % W] = true
		if c == 0:
			if st != SimBoard.NORMAL or b.tm[i] != 0 or b.gid[i] != 0 or b.chain[i] != 0 or b.reveal[i] != 0:
				_v("empty cell has state", tick, b)
			continue
		if not ((c >= 1 and c <= SimConst.COLORS) or c == SimConst.GARBAGE):
			_v("bad colour", tick, b)
		if (c == SimConst.GARBAGE) != (b.gid[i] != 0):
			_v("garbage colour and id disagree", tick, b)
		if b.tm[i] < 0:
			_v("negative timer", tick, b)
		if st != SimBoard.NORMAL and b.tm[i] <= 0:
			_v("active state with no timer", tick, b)
		if st != SimBoard.NORMAL and not b.busy:
			_v("active cell on a board marked idle", tick, b)
		if b.gid[i] != 0:
			if not slabs.has(b.gid[i]):
				slabs[b.gid[i]] = []
			slabs[b.gid[i]].append(i)
	for g: int in slabs:
		_inv_slab(b, slabs[g], swap_col, tick)
	# A chain flag lasts only while a panel is in motion, so a swap can never move one.
	if not b.need_support and not b.need_scan:
		for i in N:
			if b.chain[i] != 0 and b._resting(i):
				_v("resting panel still flagged as chain", tick, b)
	if not b.need_support:
		for i in range(0, N - W):
			if b.color[i] != 0 and b.gid[i] == 0 and b._resting(i) and b.color[i + W] == 0 and not _near_swap(swap_col, i % W):
				_v("panel floating at rest", tick, b)
	if not b.need_scan:
		_inv_matches(b, tick)
	if b.cursor_x < 0 or b.cursor_x > W - 2 or b.cursor_y < SimBoard.TOP or b.cursor_y >= ROWS:
		_v("cursor out of bounds", tick, b)
	if b.rise < 0 or b.rise > SimConst.ROW_UNITS:
		_v("rise out of bounds", tick, b)
	if b.time_rate < SimConst.TIME_SLOW or b.time_rate > SimConst.TIME_UNIT:
		_v("time rate out of bounds", tick, b)
	if b.chain_n > 1:
		_cov["chain"] = maxi(_cov.get("chain", 0), b.chain_n)
	if b.time_rate < SimConst.TIME_UNIT:
		_cov["bullet_time"] = 1
	if b.topped():
		_cov["topped"] = 1


func _inv_slab(b: SimBoard, cells: Array, swap_col: Array, tick: int) -> void:
	var x0 := W
	var x1 := -1
	var y0 := ROWS
	var y1 := -1
	var st0: int = b.st[cells[0]]
	for i: int in cells:
		x0 = mini(x0, i % W)
		x1 = maxi(x1, i % W)
		y0 = mini(y0, i / W)
		y1 = maxi(y1, i / W)
		if b.st[i] != st0:
			_v("slab with mixed states", tick, b)
	if (x1 - x0 + 1) * (y1 - y0 + 1) != cells.size():
		_v("slab is not a rectangle", tick, b)
	if st0 == SimBoard.MATCHED:
		_cov["garbage_cracked"] = 1
	if b.need_support or st0 != SimBoard.NORMAL or y1 + 1 >= ROWS:
		return
	for x in range(x0, x1 + 1):
		if b.color[(y1 + 1) * W + x] != 0 or _near_swap(swap_col, x):
			return
	_v("slab floating at rest", tick, b)


## A swap into an empty cell leaves the vacated column with no state, and whatever
## rests above it only starts to fall when the swap ends. Neighbours count too.
func _near_swap(swap_col: Array, x: int) -> bool:
	return swap_col[x] or (x > 0 and swap_col[x - 1]) or (x < W - 1 and swap_col[x + 1])


func _inv_matches(b: SimBoard, tick: int) -> void:
	for y in ROWS:
		for x in W:
			var i := y * W + x
			if not b._matchable(i):
				continue
			if x + 2 < W and b._matchable(i + 1) and b._matchable(i + 2) and b.color[i] == b.color[i + 1] and b.color[i] == b.color[i + 2]:
				_v("missed horizontal match", tick, b)
			if y + 2 < ROWS and b._matchable(i + W) and b._matchable(i + 2 * W) and b.color[i] == b.color[i + W] and b.color[i] == b.color[i + 2 * W]:
				_v("missed vertical match", tick, b)


func _settled(b: SimBoard) -> bool:
	if b.chain_n != 1:
		return false
	for i in N:
		if b.color[i] != 0 and not b._resting(i):
			return false
	return true


func _chaos(rng: RandomNumberGenerator, st: Dictionary) -> int:
	st.t -= 1
	if st.t <= 0:
		st.t = rng.randi_range(1, 20)
		st.m = SimConst.target(rng.randi() % (W - 1), rng.randi() % SimConst.H)
		if rng.randf() < _raise_p:
			st.m |= SimConst.RAISE
		st.swap = rng.randf() < 0.8
	var m: int = st.m
	if st.swap and st.t % 2 == 0:
		m |= SimConst.SWAP
	return m


# --- fuzz ---------------------------------------------------------------------

func _fuzz(sd: int, budget: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = sd * 31337 + 1
	var ticks := 0
	var games := 0
	var forks := 0
	var drains := 0
	while ticks < budget:
		games += 1
		var s := SimState.create(rng.randi())
		var c0 := {"t": 0, "m": 0, "swap": false}
		var c1 := {"t": 0, "m": 0, "swap": false}
		var since_drain := 0
		var next_garbage := 2000
		while s.winner == -1 and ticks < budget:
			var i0 := _chaos(rng, c0)
			var i1 := _chaos(rng, c1)
			s.step(i0, i1)
			ticks += 1
			if s.tick % 7 == 0:
				_inv(s.boards[0], s.tick)
				_inv(s.boards[1], s.tick)
			next_garbage -= 1
			if next_garbage <= 0 and s.tick > SimConst.COUNTDOWN_TICKS:
				next_garbage = rng.randi_range(1000, 6000)
				var w := rng.randi_range(3, 6)
				var h := 1 if w < 6 else rng.randi_range(1, 4)
				s.boards[rng.randi() % 2].receive_garbage(PackedInt32Array([SimConst.slab(w, h)]))
			# A snapshot must equal the original, and stay equal when both are stepped.
			if s.tick % 1009 == 0:
				var a := s.copy()
				var b := s.copy()
				if a.checksum() != s.checksum():
					_fail("copy() changed the checksum at tick %d" % s.tick)
				for _k in 300:
					a.step(i0, i1)
					b.step(i0, i1)
				if a.checksum() != b.checksum():
					_fail("two copies diverged at tick %d" % s.tick)
				forks += 1
			# Hands off: with no input, nothing may stay stuck.
			since_drain += 1
			if since_drain > TICK_HZ * 25:
				since_drain = 0
				drains += 1
				var drained := false
				for _k in TICK_HZ * 30:
					s.step(0, 0)
					ticks += 1
					if s.winner != -1 or (_settled(s.boards[0]) and _settled(s.boards[1])):
						drained = true
						break
				if not drained:
					_v("board stuck after 30 s without input", s.tick, s.boards[0])
	print("fuzz: %d ticks, %d games, %d snapshot checks, %d drains, coverage %s" % [ticks, games, forks, drains, _cov])
	for name: String in _viol:
		_fail("%s: %d times, first at tick %d\n%s" % [name, _viol[name].n, _viol[name].tick, _viol[name].board])
	for need: String in ["garbage_cracked", "bullet_time", "chain"]:
		if not _cov.has(need):
			_fail("fuzz never reached %s" % need)


# --- P1/P2 fairness -----------------------------------------------------------

## Swapping the players' inputs must swap the boards exactly, right through to the winner.
func _mirror(sd: int, budget: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = sd * 271 + 3
	var ticks := 0
	var games := 0
	var decided := 0
	while ticks < budget:
		games += 1
		var game_seed := rng.randi()
		var a := SimState.create(game_seed)
		var b := SimState.create(game_seed)
		var c0 := {"t": 0, "m": 0, "swap": false}
		var c1 := {"t": 0, "m": 0, "swap": false}
		var t := 0
		var ok := true
		# Chaos for a minute, then one side tops itself out so the winner gets compared too.
		var loser := rng.randi() % 2
		while ok and a.winner == -1 and t < TICK_HZ * 600:
			var i0 := _chaos(rng, c0)
			var i1 := _chaos(rng, c1)
			if t >= TICK_HZ * 60:
				i0 = SimConst.RAISE if loser == 0 else 0
				i1 = SimConst.RAISE if loser == 1 else 0
			a.step(i0, i1)
			b.step(i1, i0)
			t += 1
			if t % 97 == 0 and (a.boards[0].checksum() != b.boards[1].checksum() or a.boards[1].checksum() != b.boards[0].checksum()):
				_fail("mirror game %d diverged by tick %d" % [games, t])
				ok = false
		ticks += t
		var mirrored := b.winner
		if b.winner == 0 or b.winner == 1:
			mirrored = 1 - b.winner
		if ok and a.winner != mirrored:
			_fail("mirror game %d: winner %d vs mirrored %d" % [games, a.winner, mirrored])
		if a.winner != -1:
			decided += 1
	print("mirror: %d ticks, %d games, %d decided" % [ticks, games, decided])
	if decided == 0:
		_fail("no mirror game reached a winner")
