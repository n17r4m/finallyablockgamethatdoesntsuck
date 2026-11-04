extends SceneTree
## Rollback sessions under realistic network failures, driven the way scenes/match.gd
## drives them: wall-clock ticks, capped catch-up, and no banking of ticks lost to a stall.
##   godot --headless --path . -s tests/test_net_matrix.gd [-- --seeds=4 --cpu=0]
##
## Every run must never desync and must converge to the exact state an offline replay of
## the agreed inputs produces. Profiles also check fairness: once settled, neither side may
## carry the rollbacks alone. A sabotaged run proves the desync detector can actually fire.

const TPF := SimConst.TICKS_PER_FRAME
const FRAMES := 60 * 60 # one minute at 60 fps
const WINDOW := FRAMES - 60 * 20 # steady state is measured over the last 20 s
const MS_PER_TICK := 1000.0 / SimConst.TICK_HZ
# Rollback milliseconds per second may differ by this factor once settled...
const FAIR_RATIO := 1.6
# ...unless both are below this: about 10 input changes a second, each rolled back one
# 16.7 ms frame. Rollback comes in whole frames, so nothing finer can be told apart.
const FAIR_FLOOR := 170.0

# ab / ba: one-way latency in frames towards client b / client a.
const PROFILES := {
	"lan": {"ab": [1, 1], "ba": [1, 1], "loss": 0.0},
	"broadband": {"ab": [2, 3], "ba": [2, 3], "loss": 0.005},
	"wifi_jitter": {"ab": [1, 8], "ba": [1, 8], "loss": 0.03},
	"wan_bad": {"ab": [6, 12], "ba": [6, 12], "loss": 0.10},
	"asymmetric": {"ab": [1, 1], "ba": [9, 9], "loss": 0.0},
	"blackout_2s": {"ab": [2, 3], "ba": [2, 3], "loss": 0.005, "blackout": [1800, 120]},
	"pause_a_1s": {"ab": [2, 3], "ba": [2, 3], "loss": 0.005, "pause": [0, 1800, 60]},
	"pause_a_3s": {"ab": [2, 3], "ba": [2, 3], "loss": 0.005, "pause": [0, 1800, 180]},
	"late_start_200ms": {"ab": [2, 3], "ba": [2, 3], "loss": 0.005, "late": [1, 12]},
	"drift_0.1pct": {"ab": [2, 3], "ba": [2, 3], "loss": 0.005, "drift_ppm": 1000},
	# Bufferbloat: one direction queues for 1 s. Nothing is lost and nobody freezes.
	"oneway_spike_1s": {"ab": [2, 3], "ba": [2, 3], "loss": 0.0, "spike": [1, 1800, 60]},
}

var _failed := 0


func _init() -> void:
	var seeds := 4
	var cpu_seeds := 0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seeds="):
			seeds = a.trim_prefix("--seeds=").to_int()
		elif a.begins_with("--cpu="):
			cpu_seeds = a.trim_prefix("--cpu=").to_int()

	_test_frontier_never_contradicted()
	_test_detector_fires()
	print("%-18s %-6s %6s %7s %8s %12s %12s %9s" % ["profile", "bot", "runs", "desyncs", "gap ms", "rb ms/s a", "rb ms/s b", "ticks/s"])
	for pname: String in PROFILES:
		_run_profile(pname, "human", seeds, 1)
		if cpu_seeds > 0:
			_run_profile(pname, "cpu", cpu_seeds, 101)
	print("PASS" if _failed == 0 else "FAIL (%d)" % _failed)
	quit(0 if _failed == 0 else 1)


func _fail(what: String) -> void:
	_failed += 1
	print("  FAIL " + what)


## A client that can't make progress must not change its mind about a tick it already
## declared final. The peer discards such a change as stale, which is a guaranteed desync.
func _test_frontier_never_contradicted() -> void:
	var s := RollbackSession.new(1, 1, 2 * TPF) # the peer never answers, so this stalls
	var seen := {}
	var sent_frontier := [-1]
	var bad := [0]
	s.outgoing.connect(func(p: Dictionary) -> void:
		for t in p.t:
			if not seen.has(t):
				seen[t] = true
				if t <= sent_frontier[0]:
					bad[0] += 1
		sent_frontier[0] = maxi(sent_frontier[0], p.f))
	# Hold still until a whole frame makes no progress, so that frame's frontier goes out
	# with the input unchanged. Only then does the player press something.
	var stuck_frames := 0
	for f in 600:
		if s.input_open():
			s.set_local_input(SimConst.SWAP if stuck_frames > 0 else 0)
		if s.advance(TPF) == 0:
			stuck_frames += 1
	if stuck_frames == 0:
		_fail("frontier test never stalled")
	if bad[0] > 0:
		_fail("%d input changes contradicted a frontier already sent" % bad[0])


## Corrupt one client and its rollback history: the checksum exchange has to notice.
func _test_detector_fires() -> void:
	var r := _run("lan", 1, "human", 900)
	if r.desyncs == 0 or r.converged:
		_fail("sabotaged run went undetected")


func _run_profile(pname: String, bot: String, n: int, first_seed: int) -> void:
	var desyncs := 0
	var unconverged := 0
	var gap := 0.0
	var burden := [0.0, 0.0]
	var ticks := 0
	for i in n:
		var r := _run(pname, first_seed + i, bot)
		desyncs += r.desyncs
		unconverged += 0 if r.converged else 1
		gap += r.gap_ms / n
		burden[0] += r.burden[0] / n
		burden[1] += r.burden[1] / n
		ticks += r.ticks
	print("%-18s %-6s %6d %7d %8.1f %12.1f %12.1f %9d" % [pname, bot, n, desyncs, gap, burden[0], burden[1], ticks / maxi(n, 1) / 60])
	if desyncs > 0:
		_fail("%s/%s: %d desyncs" % [pname, bot, desyncs])
	if unconverged > 0:
		_fail("%s/%s: %d runs did not converge" % [pname, bot, unconverged])
	# Rollbacks on one side come from the other side's inputs, so loads only compare when
	# both play at the same rate. CPU players don't, and stop altogether once they lose.
	var high := maxf(burden[0], burden[1])
	if bot == "human" and high > FAIR_FLOOR and high > FAIR_RATIO * minf(burden[0], burden[1]):
		_fail("%s/%s: unfair rollbacks, %.0f vs %.0f ms/s" % [pname, bot, burden[0], burden[1]])


func _run(pname: String, sd: int, bot: String, sabotage_frame := -1) -> Dictionary:
	var p: Dictionary = PROFILES[pname]
	var rng := RandomNumberGenerator.new()
	rng.seed = sd * 7919 + 13
	var game_seed := sd * 104729 + 7
	var sess: Array[RollbackSession] = [RollbackSession.new(game_seed, 0, 2 * TPF), RollbackSession.new(game_seed, 1, 2 * TPF)]
	var q: Array = [[], []] # q[i] = packets inbound to client i
	var frame := [0]
	var lossy := [true]
	var desyncs := [0]
	for s in sess:
		s.desynced.connect(func(_t: int) -> void: desyncs[0] += 1)
	var link := func(to: int, pkt: Dictionary) -> void:
		if not lossy[0]:
			q[to].append([frame[0] + 1, pkt])
			return
		if p.has("blackout") and frame[0] >= p.blackout[0] and frame[0] < p.blackout[0] + p.blackout[1]:
			return
		if rng.randf() < p.loss:
			return
		var lat: Array = p.ab if to == 1 else p.ba
		var arrive: int = frame[0] + rng.randi_range(lat[0], lat[1])
		if p.has("spike") and to == p.spike[0] and frame[0] >= p.spike[1] and frame[0] < p.spike[1] + p.spike[2]:
			arrive = maxi(arrive, p.spike[1] + p.spike[2])
		q[to].append([arrive, pkt])
	sess[0].outgoing.connect(func(pk: Dictionary) -> void: link.call(1, pk))
	sess[1].outgoing.connect(func(pk: Dictionary) -> void: link.call(0, pk))

	var bots := [{"hold": 0, "mask": 0}, {"hold": 0, "mask": 0}]
	var cpus: Array = []
	if bot == "cpu":
		cpus = [CpuPlayer.opponent("Overmind", "normal", sd), CpuPlayer.opponent("Overmind", "normal", sd + 1)]
	var acc := [0, 0]
	var drift_ppm: int = p.get("drift_ppm", 0)
	var drift_acc := 0
	var rolled := [0, 0]
	var gap_sum := 0
	var last_inputs := [0, 0]

	for f in FRAMES:
		frame[0] = f
		if f == sabotage_frame:
			sess[0].state.boards[1].rng ^= 0x5555
			for k: int in sess[0]._snaps:
				sess[0]._snaps[k].boards[1].rng ^= 0x5555
		for c in 2:
			var s := sess[c]
			if p.has("late") and p.late[0] == c and f < p.late[1]:
				_deliver(q[c], s, f)
				continue
			var extra := 0
			if c == 1 and drift_ppm != 0:
				drift_acc += TPF * drift_ppm
				extra = drift_acc / 1000000
				drift_acc -= extra * 1000000
			acc[c] += TPF + extra
			if p.has("pause") and p.pause[0] == c and f >= p.pause[1] and f < p.pause[1] + p.pause[2]:
				continue # frozen: no receive, no send, but the wall clock keeps accumulating
			_deliver(q[c], s, f)
			# scenes/match.gd: due is capped at 100 ms of ticks and the rest is thrown away.
			var due: int = mini(acc[c], SimConst.TICK_HZ / 10)
			acc[c] = mini(acc[c] - due, 1)
			if s.input_open():
				var m: int = cpus[c].next_input(s.state.boards[c]) if bot == "cpu" else _human(rng, bots[c])
				s.set_local_input(m)
				last_inputs[c] = m
			if f >= WINDOW and s._rewind_to < s.state.tick:
				rolled[c] += s.state.tick - s._rewind_to
			s.advance(due)
		if f >= WINDOW:
			gap_sum += sess[0].state.tick - sess[1].state.tick

	# Settle on a clean link, then both must equal an offline replay of the agreed inputs.
	lossy[0] = false
	var target: int = maxi(sess[0].state.tick, sess[1].state.tick) + 4 * TPF
	for f in range(FRAMES, FRAMES + 240):
		frame[0] = f
		for c in 2:
			_deliver(q[c], sess[c], f)
		for c in 2:
			sess[c].set_local_input(last_inputs[c])
			sess[c].advance(maxi(target - sess[c].state.tick, 0))
	var replay := SimState.create(game_seed)
	while replay.tick < target:
		replay.step(sess[0].input_at(0, replay.tick), sess[0].input_at(1, replay.tick))
	var secs := (FRAMES - WINDOW) / 60.0
	return {
		"desyncs": desyncs[0],
		"converged": sess[0].state.tick == target and sess[1].state.tick == target
				and sess[0].state.checksum() == sess[1].state.checksum()
				and sess[0].state.checksum() == replay.checksum(),
		"gap_ms": float(gap_sum) / (FRAMES - WINDOW) * MS_PER_TICK,
		"burden": [rolled[0] * MS_PER_TICK / secs, rolled[1] * MS_PER_TICK / secs],
		"ticks": target,
	}


## About ten input changes a second, roughly a fast human on a keyboard.
func _human(rng: RandomNumberGenerator, st: Dictionary) -> int:
	if st.hold > 0:
		st.hold -= 1
		return st.mask
	var picks := [SimConst.LEFT, SimConst.RIGHT, SimConst.UP, SimConst.DOWN, SimConst.SWAP, SimConst.SWAP, 0, 0]
	st.mask = picks[rng.randi() % picks.size()]
	st.hold = rng.randi_range(2, 6)
	return st.mask


func _deliver(queue: Array, s: RollbackSession, f: int) -> void:
	var i := 0
	while i < queue.size():
		if queue[i][0] <= f:
			s.receive(queue[i][1])
			queue.remove_at(i)
		else:
			i += 1
