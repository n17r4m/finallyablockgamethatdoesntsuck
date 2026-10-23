extends SceneTree
## Headless soak: two sessions over a fake lossy, laggy, reordering link with
## clock drift. Passes if they never desync and converge to the exact state an
## offline replay of the agreed inputs produces.
##   godot --headless --path . -s tests/test_netcode.gd

const FRAMES := 3600 # one minute at 60 fps
const TPF := SimConst.TICKS_PER_FRAME


func _init() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var game_seed := 98765
	var delay := 2 * TPF
	var a := RollbackSession.new(game_seed, 0, delay)
	var b := RollbackSession.new(game_seed, 1, delay)
	# Pre-seed identical 5-combos on every board so garbage crosses the link under rollback.
	for st: SimState in [a.state, b.state]:
		for board in st.boards:
			for c in [[0, 11], [1, 11], [2, 11], [0, 10], [0, 9]]:
				board.cells[c[1] * SimConst.W + c[0]] = 6
			board.unsettled = true
	var desyncs := [0]
	var frame := [0]
	var lossy := [true]
	var to_a := []
	var to_b := []
	a.desynced.connect(func(_t: int) -> void: desyncs[0] += 1)
	b.desynced.connect(func(_t: int) -> void: desyncs[0] += 1)
	var link := func(queue: Array, pkt: Dictionary) -> void:
		if lossy[0]:
			if rng.randf() < 0.1:
				return # 10% loss
			queue.append([frame[0] + rng.randi_range(2, 9), pkt]) # 33-150 ms one-way, reorders
		else:
			queue.append([frame[0] + 1, pkt])
	a.outgoing.connect(func(p: Dictionary) -> void: link.call(to_b, p))
	b.outgoing.connect(func(p: Dictionary) -> void: link.call(to_a, p))

	var mask_a := 0
	var mask_b := 0
	var t0 := Time.get_ticks_usec()
	for f in FRAMES:
		frame[0] = f
		if rng.randf() < 0.3:
			mask_a = rng.randi() & 63
		if rng.randf() < 0.3:
			mask_b = rng.randi() & 63
		_deliver(to_a, a, f)
		_deliver(to_b, b, f)
		a.set_local_input(mask_a)
		a.advance(TPF)
		b.set_local_input(mask_b)
		b.advance(TPF + (1 if f % 7 == 0 else 0)) # b's clock runs fast
	var usec := Time.get_ticks_usec() - t0
	var ticks_run: int = a.state.tick + b.state.tick + a.stats.resim + b.stats.resim

	# Settle: clean link, inputs held, march both to the same tick.
	lossy[0] = false
	var target := maxi(a.state.tick, b.state.tick) + 4 * TPF
	for f in range(FRAMES, FRAMES + 120):
		frame[0] = f
		_deliver(to_a, a, f)
		_deliver(to_b, b, f)
		a.set_local_input(mask_a)
		a.advance(maxi(target - a.state.tick, 0))
		b.set_local_input(mask_b)
		b.advance(maxi(target - b.state.tick, 0))

	var replay := SimState.create(game_seed)
	for board in replay.boards:
		for c in [[0, 11], [1, 11], [2, 11], [0, 10], [0, 9]]:
			board.cells[c[1] * SimConst.W + c[0]] = 6
		board.unsettled = true
	while replay.tick < target:
		replay.step(a.input_at(0, replay.tick), a.input_at(1, replay.tick))

	print("a stats ", a.stats, "  b stats ", b.stats)
	print("ticks a=%d b=%d target=%d  scores %d/%d  desyncs=%d" % [a.state.tick, b.state.tick,
			target, replay.boards[0].score, replay.boards[1].score, desyncs[0]])
	print("garbage slabs dropped: %d / %d" % [replay.boards[0].next_gid - 1, replay.boards[1].next_gid - 1])
	print("%.2f us per sim tick (incl. resim) -> %.1f%% of a 60fps frame at 1080 Hz" % [
			float(usec) / ticks_run, float(usec) / ticks_run * 1080.0 / 16667.0 * 100.0])
	var ok: bool = (desyncs[0] == 0 and a.state.tick == target and b.state.tick == target
			and a.state.checksum() == b.state.checksum()
			and a.state.checksum() == replay.checksum()
			and a.stats.rollbacks > 0 and b.stats.rollbacks > 0
			and replay.boards[0].next_gid > 1 and replay.boards[1].next_gid > 1)
	print("PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _deliver(queue: Array, s: RollbackSession, f: int) -> void:
	var i := 0
	while i < queue.size():
		if queue[i][0] <= f:
			s.receive(queue[i][1])
			queue.remove_at(i)
		else:
			i += 1
