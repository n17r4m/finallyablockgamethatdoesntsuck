extends SceneTree
## The engine contract: every recorded game must still play out exactly as recorded, and
## between them they must reach what the corpus claims to cover. Damaged or forged replays
## must be refused. If a rule changed on purpose: bump SimConst.RULES_VERSION, then run
## tools/make_golden.gd.
##   godot --headless --path . -s tests/test_golden.gd

const DIR := "res://tests/golden"

var _failed := 0


func _init() -> void:
	_test_corpus()
	_test_vectors()
	_test_session_replays()
	_test_damage()
	_test_forgery()
	print("PASS" if _failed == 0 else "FAIL (%d)" % _failed)
	quit(0 if _failed == 0 else 1)


func _fail(what: String) -> void:
	_failed += 1
	print("  FAIL " + what)


func _files() -> Array[String]:
	var out: Array[String] = []
	for f in DirAccess.get_files_at(DIR):
		if f.ends_with(".fbgr"):
			out.append(f)
	out.sort()
	return out


func _load(name: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes("%s/%s" % [DIR, name])


# --- the corpus -----------------------------------------------------------------

func _test_corpus() -> void:
	var cov := {"combos": {}, "slabs": {}, "winners": {}, "chain": 0, "bullet": false, "topped": false, "cracked": false, "solo": false, "subframe": false}
	var files := _files()
	if files.size() < 40:
		_fail("only %d golden replays" % files.size())
	var ticks := 0
	for name in files:
		var bytes := _load(name)
		var r := Replay.decode(bytes)
		if r.error != "":
			_fail("%s: %s" % [name, r.error])
			continue
		if r.encode() != bytes:
			_fail("%s: doesn't re-encode to the same bytes" % name)
		var err := r.verify(func(s: SimState) -> void: _observe(s, cov))
		if err != "":
			_fail("%s: %s. If this rule change is on purpose, see this file's header." % [name, err])
			continue
		ticks += r.end_tick
		cov.solo = cov.solo or r.solo
		var w := r.final_state.winner
		if w != -1 and not r.solo:
			cov.winners[w] = true
		for p in 2:
			for t in r.ticks[p]:
				if t % SimConst.TICKS_PER_FRAME != 0:
					cov.subframe = true
	print("corpus: %d replays, %d ticks, coverage %s" % [files.size(), ticks, cov])
	for n in range(4, 15):
		if not cov.combos.has(n):
			_fail("no golden replay has a combo of %d" % n)
	if cov.chain < 8:
		_fail("longest golden chain is %d" % cov.chain)
	for s: int in [SimConst.slab(3, 1), SimConst.slab(4, 1), SimConst.slab(5, 1), SimConst.slab(6, 1), SimConst.slab(6, 2), SimConst.slab(6, 12)]:
		if not cov.slabs.has(s):
			_fail("no golden replay has a %dx%d slab" % [s % 8, s / 8])
	for w in [0, 1, 2]:
		if not cov.winners.has(w):
			_fail("no golden replay ends with winner %d" % w)
	for need: String in ["bullet", "topped", "cracked", "solo", "subframe"]:
		if not cov[need]:
			_fail("no golden replay covers %s" % need)


func _observe(s: SimState, cov: Dictionary) -> void:
	for b: SimBoard in s.boards:
		if b.fx_combo >= 4:
			cov.combos[b.fx_combo] = true
		cov.chain = maxi(cov.chain, b.chain_n)
		for slab in b.gar_q:
			cov.slabs[slab] = true
		cov.bullet = cov.bullet or b.time_rate < SimConst.TIME_UNIT
		cov.cracked = cov.cracked or b.cracking
		if s.tick % SimConst.TICKS_PER_FRAME == 0:
			cov.topped = cov.topped or b.topped()


# --- hash test vectors ----------------------------------------------------------

func _test_vectors() -> void:
	var vectors: Variant = JSON.parse_string(FileAccess.get_file_as_string("%s/vectors.json" % DIR))
	if not vectors is Array or vectors.size() < 3:
		_fail("vectors.json is missing or short")
		return
	for v: Dictionary in vectors:
		var r := Replay.decode(_load(v.replay + ".fbgr"))
		var want := int(v.tick)
		var got := []
		if want == 0:
			got.append(r.new_state().canonical_bytes())
		else:
			r.verify(func(s: SimState) -> void:
				if s.tick == want:
					got.append(s.canonical_bytes()))
		if got.size() != 1:
			_fail("vector %s@%d never happened" % [v.replay, want])
			continue
		if got[0].hex_encode() != v.bytes:
			_fail("vector %s@%d: state bytes differ" % [v.replay, want])
		var h := PackedByteArray()
		h.resize(8)
		h.encode_s64(0, SimConst.hash64(got[0]))
		if h.hex_encode() != v.hash:
			_fail("vector %s@%d: hash differs" % [v.replay, want])


# --- replays recorded the way real matches record them -------------------------------

func _test_session_replays() -> void:
	# CPU opponent, offline, driven as scenes/match.gd drives it.
	var s := RollbackSession.new(4242, 0, 2 * SimConst.TICKS_PER_FRAME, true, false)
	var c0 := CpuPlayer.opponent("Overmind", "normal", 1)
	var c1 := CpuPlayer.opponent("Architect", "normal", 2)
	for _f in 60 * 40:
		if s.input_open():
			s.set_local_input(c0.next_input(s.state.boards[0]))
		s.set_remote_input(c1.next_input(s.state.boards[1]))
		s.advance(SimConst.TICKS_PER_FRAME)
	_check_session(s, "offline")
	# Solo practice.
	var solo := RollbackSession.new(4243, 0, 0, true)
	for f in 60 * 20:
		if solo.input_open():
			solo.set_local_input(SimConst.SWAP if f % 20 == 0 else (SimConst.LEFT if f % 7 == 0 else 0))
		solo.advance(SimConst.TICKS_PER_FRAME)
	_check_session(solo, "solo")
	# A match that ended before its first checkpoint has nothing to save.
	var short := RollbackSession.new(1, 0, 0, true)
	short.advance(SimConst.TICK_HZ - 1)
	if Replay.from_session(short) != null:
		_fail("a game under a second long produced a replay")


func _check_session(s: RollbackSession, what: String) -> void:
	var r := Replay.from_session(s)
	if r == null:
		_fail("%s: no replay" % what)
		return
	var back := Replay.decode(r.encode())
	if back.error != "":
		_fail("%s: %s" % [what, back.error])
		return
	var err := back.verify()
	if err != "":
		_fail("%s: %s" % [what, err])


# --- damage -----------------------------------------------------------------------

func _test_damage() -> void:
	var good := _load("controls.fbgr")
	if good.size() > 4000:
		good = _load("combo_03.fbgr")
	# Every single-bit flip and every truncation of a real file.
	var missed := 0
	for i in good.size():
		var bad := good.duplicate()
		bad[i] ^= 1 << (i % 8)
		if Replay.decode(bad).error == "":
			missed += 1
		if Replay.decode(good.slice(0, i)).error == "":
			missed += 1
	if missed > 0:
		_fail("%d damaged files were accepted" % missed)
	# Sealed noise reaches the parser itself, past the trailer, and must still be refused.
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var accepted := 0
	for _i in 3000:
		var noise := good.slice(0, 4 + 1 + 2 + 2 + 1 + 8) # a valid header, so the parser runs...
		for _k in rng.randi_range(0, 200):
			noise.append(rng.randi() & (0x7F if rng.randf() < 0.7 else 0xFF)) # ...then varint-heavy noise
		if Replay.decode(Replay.seal(noise)).error == "":
			accepted += 1
	if accepted > 0:
		_fail("%d noise files parsed as replays" % accepted)


# --- forgery ----------------------------------------------------------------------

## Well-formed files with valid trailers that lie about what happened.
func _test_forgery() -> void:
	var bytes := _load("cpu_1.fbgr")
	# Pressing swap one tick later than recorded.
	var r := Replay.decode(bytes)
	var moved := false
	for i in r.ticks[0].size():
		if r.masks[0][i] & SimConst.SWAP and r.ticks[0][i] > SimConst.COUNTDOWN_TICKS:
			r.masks[0][i] ^= SimConst.SWAP
			moved = true
			break
	if not moved:
		_fail("forgery test found no swap to remove")
	var forged := Replay.decode(r.encode())
	if forged.error != "" or forged.verify() == "":
		_fail("a replay with an input removed verified: '%s'" % forged.error)
	# A rigged final checkpoint.
	r = Replay.decode(bytes)
	r.check_hashes[-1] ^= 1
	if Replay.decode(r.encode()).verify() == "":
		_fail("a replay with a rigged checkpoint verified")
	# A rigged start state.
	r = Replay.decode(bytes)
	r.game_seed ^= 2
	if Replay.decode(r.encode()).verify() == "":
		_fail("a replay with another seed verified")
	# Things that must never parse, however well sealed.
	_refused("unknown input bits", func(x: Replay) -> void: x.masks[0][0] = 1 << 20)
	_refused("ticks that don't ascend", func(x: Replay) -> void: x.ticks[0][1] = x.ticks[0][0])
	_refused("a two-hour-plus game", func(x: Replay) -> void: x.end_tick = Replay.MAX_TICKS + 1)
	_refused("a checkpoint short of the end", func(x: Replay) -> void: x.end_tick += 1)
	_refused("a cell out of bounds", func(x: Replay) -> void: x.setup = [[Replay.OP_PUT, 0, 6, 0, 1]])
	_refused("a garbage-coloured cell", func(x: Replay) -> void: x.setup = [[Replay.OP_PUT, 0, 0, 0, SimConst.GARBAGE]])
	_refused("a slab too wide", func(x: Replay) -> void: x.setup = [[Replay.OP_GARBAGE, 0, 7, 1]])
	_refused("a third board", func(x: Replay) -> void: x.setup = [[Replay.OP_CLEAR, 2]])
	# Readable, but must not verify on this build.
	var other := Replay.decode(bytes)
	other.rules += 1
	if Replay.decode(other.encode()).verify() == "":
		_fail("a replay from other rules verified")
	other = Replay.decode(bytes)
	other.tick_hz = 1080
	if Replay.decode(other.encode()).verify() == "":
		_fail("a replay at another tick rate verified")


func _refused(what: String, change: Callable) -> void:
	var r := Replay.decode(_load("cpu_1.fbgr"))
	change.call(r)
	if Replay.decode(r.encode()).error == "":
		_fail("parsed a replay with %s" % what)
