extends SceneTree
## The game on the Rust rules must play exactly as it does on GDScript's: what readers see,
## what CPU players decide, and what a Rust player and a GDScript player agree on online.
##   godot --headless --path . -s tests/test_backends.gd

const TPF := SimConst.TICKS_PER_FRAME
const FRAMES := 60 * 45 # 45 s at 60 fps, enough for CPU games to send garbage both ways

var _failed := 0


func _init() -> void:
	if not RustState.available():
		_fail("the Rust extension isn't available: run tools/build_rust_ext.sh linux")
	else:
		_test_auto_picks_rust()
		_test_view_is_complete()
		_test_same_game_on_both()
		_test_mixed_online(0)
		_test_mixed_online(1)
		_test_cost()
	print("PASS" if _failed == 0 else "FAIL (%d)" % _failed)
	quit(0 if _failed == 0 else 1)


func _fail(what: String) -> void:
	_failed += 1
	print("  FAIL " + what)


func _test_auto_picks_rust() -> void:
	if not RollbackSession.new(1, 0, 0, true, false, "auto").state is RustState:
		_fail("auto didn't pick Rust")
	if RollbackSession.new(1, 0, 0, true, false, "gdscript").state is RustState:
		_fail("gdscript picked Rust")
	if RollbackSession.new(1, 0, 0, true, false).state is RustState:
		_fail("sessions must stay on GDScript unless asked")


func _offline(game_seed: int, backend: String) -> RollbackSession:
	return RollbackSession.new(game_seed, 0, 0, true, false, backend)


## Plays one frame the way scenes/match.gd does.
func _frame(s: RollbackSession, cpus: Array[CpuPlayer]) -> void:
	s.set_local_input(cpus[0].next_input(s.state.boards[0]))
	s.set_remote_input(cpus[1].next_input(s.state.boards[1]))
	s.advance(TPF)


func _cpus(game_seed: int) -> Array[CpuPlayer]:
	return [CpuPlayer.opponent("Overmind", "hard", game_seed), CpuPlayer.opponent("Architect", "hard", game_seed + 1)]


## Rebuilds the hash input from the boards readers get, on a live game with cracks, garbage
## and chains in it. A field missing, misplaced or mistyped changes the bytes.
func _test_view_is_complete() -> void:
	var s := _offline(1275, "auto")
	var cpus := _cpus(1275)
	var compared := 0
	var garbage := false
	for f in FRAMES:
		_frame(s, cpus)
		garbage = garbage or not s.state.boards[0].gar_q.is_empty() or not s.state.boards[1].gar_q.is_empty()
		if f % 10 == 0:
			compared += 1
			if s.state.view_bytes() != s.state.canonical_bytes():
				_fail("view differs from the Rust state at tick %d" % s.state.tick)
				return
	if not garbage:
		_fail("the view test never saw garbage, so it proves less than it claims")
	print("  ok   view matches Rust byte for byte at %d points" % compared)


## CPU players read only the view, so a wrong view shows up as a different game.
func _test_same_game_on_both() -> void:
	for game_seed: int in [1275, 42, 777]:
		var a := _offline(game_seed, "auto")
		var b := _offline(game_seed, "gdscript")
		var ca := _cpus(game_seed)
		var cb := _cpus(game_seed)
		for f in FRAMES:
			_frame(a, ca)
			_frame(b, cb)
			if a.state.tick % SimConst.TICK_HZ == 0 and a.state.checksum() != b.state.checksum():
				_fail("seed %d: the games part at tick %d" % [game_seed, a.state.tick])
				return
			if a.state.winner != b.state.winner:
				_fail("seed %d: different winners at tick %d" % [game_seed, a.state.tick])
				return
		if a.input_log(0, a.state.tick) != b.input_log(0, b.state.tick) or a.input_log(1, a.state.tick) != b.input_log(1, b.state.tick):
			_fail("seed %d: CPU players decided differently" % game_seed)
		if a.check_log != b.check_log:
			_fail("seed %d: checkpoints differ" % game_seed)
		if a.state.view_bytes() != b.state.canonical_bytes():
			_fail("seed %d: final boards differ" % game_seed)
	print("  ok   CPU games play out identically on both")


## A Rust player against a GDScript player over a lossy, laggy link, with rollbacks on both
## sides. rust_idx says which seat runs Rust.
func _test_mixed_online(rust_idx: int) -> void:
	var game_seed := 31337 + rust_idx
	var rng := RandomNumberGenerator.new()
	rng.seed = game_seed
	var sess: Array[RollbackSession] = [null, null]
	for c in 2:
		sess[c] = RollbackSession.new(game_seed, c, 2 * TPF, false, false, "auto" if c == rust_idx else "gdscript")
	if not sess[rust_idx].state is RustState or sess[1 - rust_idx].state is RustState:
		_fail("mixed test didn't get one of each")
		return
	var q: Array = [[], []]
	var frame := [0]
	var lossy := [true]
	var desyncs := [0]
	for c in 2:
		sess[c].desynced.connect(func(_t: int) -> void: desyncs[0] += 1)
		var to := 1 - c
		sess[c].outgoing.connect(func(pk: Dictionary) -> void:
			if lossy[0]:
				if rng.randf() >= 0.05:
					q[to].append([frame[0] + rng.randi_range(2, 8), pk])
			else:
				q[to].append([frame[0] + 1, pk]))
	var cpus := _cpus(game_seed)
	var last := [0, 0]
	for f in FRAMES:
		frame[0] = f
		for c in 2:
			_deliver(q[c], sess[c], f)
			if sess[c].input_open():
				last[c] = cpus[c].next_input(sess[c].state.boards[c])
				sess[c].set_local_input(last[c])
			sess[c].advance(TPF)
	lossy[0] = false
	var target: int = maxi(sess[0].state.tick, sess[1].state.tick) + 4 * TPF
	for f in range(FRAMES, FRAMES + 240):
		frame[0] = f
		for c in 2:
			_deliver(q[c], sess[c], f)
		for c in 2:
			sess[c].set_local_input(last[c])
			sess[c].advance(maxi(target - sess[c].state.tick, 0))
	if desyncs[0] != 0:
		_fail("Rust in seat %d: %d desyncs" % [rust_idx, desyncs[0]])
	if sess[0].state.tick != target or sess[1].state.tick != target or sess[0].state.checksum() != sess[1].state.checksum():
		_fail("Rust in seat %d: the sides didn't converge" % rust_idx)
	if sess[0].stats.rollbacks + sess[1].stats.rollbacks == 0:
		_fail("Rust in seat %d: no rollbacks, so this proves little" % rust_idx)
	for s in sess:
		var saved := Replay.from_session(s)
		if saved == null or Replay.decode(saved.encode()).verify() != "":
			_fail("Rust in seat %d: a saved replay doesn't verify" % rust_idx)
	print("  ok   Rust in seat %d plays GDScript: no desync, %d and %d rollbacks" % [rust_idx, sess[0].stats.rollbacks, sess[1].stats.rollbacks])


func _deliver(queue: Array, s: RollbackSession, f: int) -> void:
	var i := 0
	while i < queue.size():
		if queue[i][0] <= f:
			s.receive(queue[i][1])
			queue.remove_at(i)
		else:
			i += 1


## What the session pays per frame, wrappers and the view included. Only a report.
func _test_cost() -> void:
	for backend: String in ["gdscript", "auto"]:
		var s := _offline(1275, backend)
		var cpus := _cpus(1275)
		var spent := 0
		var worst := 0
		for f in FRAMES:
			s.set_local_input(cpus[0].next_input(s.state.boards[0]))
			s.set_remote_input(cpus[1].next_input(s.state.boards[1]))
			var t0 := Time.get_ticks_usec()
			s.advance(TPF)
			var dt := Time.get_ticks_usec() - t0
			spent += dt
			worst = maxi(worst, dt)
		print("  info %s: %.0f µs per frame, worst %d µs" % ["Rust" if s.state is RustState else "GDScript", float(spent) / FRAMES, worst])
