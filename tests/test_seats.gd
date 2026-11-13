extends SceneTree
## Matches of any size: who's on which team, where garbage goes, who's out and who wins, and
## that GDScript and Rust agree on all of it.
##   godot --headless --path . -s tests/test_seats.gd

const EXPECTED_CHECKS := 58
const LAYOUTS := [[0, 0, 1, 1], [0, 1, 2], [0, 1, 1], [0, 1, 0, 1], [0, 0, 0, 1, 1, 1]]
const SECONDS := 40

var _failed := 0
var _ran := 0


func _init() -> void:
	_test_teams()
	for teams: Array in LAYOUTS:
		_test_game(PackedInt32Array(teams), 11 + teams.size())
	_test_mirror()
	_test_out_stays_out()
	_test_replays()
	if _ran != EXPECTED_CHECKS:
		print("  FAIL ran %d checks, expected %d" % [_ran, EXPECTED_CHECKS])
		_failed += 1
	print("PASS" if _failed == 0 else "FAIL (%d)" % _failed)
	quit(0 if _failed == 0 else 1)


func _check(ok: bool, what: String) -> void:
	_ran += 1
	if not ok:
		_failed += 1
		print("  FAIL " + what)


func _test_teams() -> void:
	_check(SimState.teams_error(PackedInt32Array([0, 1])) == "", "a 1v1 is a match")
	_check(SimState.teams_error(PackedInt32Array([1, 0, 1, 0])) == "", "teams needn't sit together")
	for bad: Array in [[], [0], [0, 0], [0, 2], [1, 1], [0, 1, 3], [-1, 0], [0, 1, 0, 1, 0, 1, 0, 1, 0]]:
		_check(SimState.teams_error(PackedInt32Array(bad)) != "", "%s isn't a match" % [bad])
	var s := SimState.create(1)
	_check(s.seats() == 2 and s.teams == PackedInt32Array([0, 1]) and s.team_count == 2, "the default is a 1v1")
	if RustState.available():
		var gd := SimState.create(5, false, null, PackedInt32Array([0, 1, 2, 0]))
		var rs := RustState.make(5, false, null, PackedInt32Array([0, 1, 2, 0]))
		_check(gd.canonical_bytes() == rs.canonical_bytes(), "both engines seat four the same")
	else:
		_check(true, "no Rust to seat")


## A CPU game on these teams, on both engines when Rust is here: they must agree every second,
## garbage must only go between teams, and the match must end with a team standing.
func _test_game(teams: PackedInt32Array, game_seed: int) -> void:
	var n := teams.size()
	# A quickly rising stack, so games end and endings get tested.
	var rules := SimRules.standard()
	rules.rise = SimRules.Line.new(SimRules.LINEAR, true, [[0, 6], [SimConst.TICK_HZ * 20, 24]])
	var gd := SimState.create(game_seed, false, rules, teams)
	var rs: SimState = RustState.make(game_seed, false, rules, teams) if RustState.available() else null
	var cpus: Array[CpuPlayer] = []
	for p in n:
		cpus.append(CpuPlayer.opponent(["Brawler", "Architect", "Overmind"][p % 3], "hard" if p == n - 1 else "easy", game_seed + p))
	var inputs := PackedInt32Array()
	inputs.resize(n)
	var got := PackedInt32Array() # garbage rows each board received
	got.resize(n)
	var agreed := true
	var frozen_ok := true
	var frozen := {} # board -> its canonical bytes when it lost
	while gd.winner == -1 and gd.tick < SimConst.TICK_HZ * SECONDS:
		for p in n:
			inputs[p] = cpus[p].next_input(gd.boards[p])
		for k in SimConst.TICKS_PER_FRAME:
			var queued := _queued(gd)
			gd.step_all(inputs)
			if rs:
				rs.step_all(inputs)
			var now := _queued(gd)
			for p in n:
				got[p] += maxi(0, now[p] - queued[p])
			if gd.tick % SimConst.TICK_HZ == 0 and rs and gd.checksum() != rs.checksum():
				agreed = false
		for p in n:
			if gd.boards[p].lost:
				var bytes := _board_bytes(gd.boards[p])
				if not frozen.has(p):
					frozen[p] = bytes
				elif frozen[p] != bytes:
					frozen_ok = false
	if rs:
		rs.refresh_view()
	var name := "%s" % [Array(teams)]
	_check(not rs or (agreed and gd.checksum() == rs.checksum() and gd.winner == rs.winner), "%s: GDScript and Rust agree" % name)
	var everyone_hit := true
	for p in n:
		everyone_hit = everyone_hit and got[p] > 0
	_check(everyone_hit, "%s: every board got garbage %s" % [name, got])
	_check(frozen_ok, "%s: a board that's out stays as it was" % name)
	var standing := {}
	for p in n:
		if not gd.boards[p].lost:
			standing[teams[p]] = true
	var ended_right: bool = gd.winner == -1 or (standing.size() == 1 and gd.winner == standing.keys()[0]) or (standing.is_empty() and gd.is_draw())
	_check(ended_right, "%s: winner %d with teams standing %s" % [name, gd.winner, standing.keys()])
	_check(gd.winner != -1, "%s: someone won within %d s (winner %d, tick %d)" % [name, SECONDS, gd.winner, gd.tick])
	var winners_won := true
	for p in n:
		winners_won = winners_won and gd.won(p) == (gd.winner == teams[p])
	_check(winners_won, "%s: won() matches the winning team" % name)
	print("  %s: winner %d at %.1f s, garbage %s" % [name, gd.winner, gd.tick / float(SimConst.TICK_HZ), got])


## Garbage cells waiting to drop on each board, counted by rows of slab. Only ever goes up when
## garbage arrives, so the rise between ticks is what came in.
func _queued(s: SimState) -> PackedInt32Array:
	var out := PackedInt32Array()
	for b in s.boards:
		var rows := 0
		for slab in b.gar_q:
			rows += slab / 8
		out.append(rows)
	return out


func _board_bytes(b: SimBoard) -> PackedByteArray:
	var out := StreamPeerBuffer.new()
	b.write_canonical(out)
	return out.data_array


## Two teams of two: renumbering the teams or rotating the seats must give the same game.
func _test_mirror() -> void:
	# Seats 0,1 against 2,3, and the same game turned round: seat p plays what seat p+2 did.
	var a := SimState.create(21, false, null, PackedInt32Array([0, 0, 1, 1]))
	var b := SimState.create(21, false, null, PackedInt32Array([1, 1, 0, 0]))
	var cpus: Array[CpuPlayer] = []
	for p in 4:
		cpus.append(CpuPlayer.opponent("Brawler", "hard", 40 + p))
	var ia := PackedInt32Array([0, 0, 0, 0])
	var ib := PackedInt32Array([0, 0, 0, 0])
	var same := true
	var teammate_hit := false
	while a.winner == -1 and a.tick < SimConst.TICK_HZ * 40:
		for p in 4:
			ia[p] = cpus[p].next_input(a.boards[p])
			ib[p] = ia[p]
		for k in SimConst.TICKS_PER_FRAME:
			var before := a.aim.duplicate()
			a.step_all(ia)
			b.step_all(ib)
			for p in 4:
				if a.aim[p] != before[p] and a.teams[(a.aim[p] + 3) % 4] == a.teams[p]:
					teammate_hit = true
		for p in 4:
			if _board_bytes(a.boards[p]) != _board_bytes(b.boards[p]):
				same = false
	_check(same and (a.winner == -1 or a.winner == 1 - b.winner), "swapping the team numbers changes nothing but the winner's name")
	_check(not teammate_hit, "garbage never aims at a teammate")
	# Now rotate the seats themselves.
	var c := SimState.create(21, false, null, PackedInt32Array([0, 0, 1, 1]))
	var d := SimState.create(21, false, null, PackedInt32Array([0, 0, 1, 1]))
	var ic := PackedInt32Array([0, 0, 0, 0])
	var id := PackedInt32Array([0, 0, 0, 0])
	var mirrored := true
	while c.winner == -1 and c.tick < SimConst.TICK_HZ * 40:
		for p in 4:
			ic[p] = cpus[p].next_input(c.boards[p])
			id[(p + 2) % 4] = ic[p]
		for k in SimConst.TICKS_PER_FRAME:
			c.step_all(ic)
			d.step_all(id)
		for p in 4:
			if _board_bytes(c.boards[p]) != _board_bytes(d.boards[(p + 2) % 4]):
				mirrored = false
	_check(mirrored, "a 2v2 is fair: the same play from the other team's seats is the same game")
	_check(c.winner == -1 or c.is_draw() or d.winner == 1 - c.winner, "and the other team wins it")


## In a three-way game, a board that's out takes no more garbage and the rest play on.
func _test_out_stays_out() -> void:
	var s := SimState.create(8, false, null, PackedInt32Array([0, 1, 2]))
	s.boards[2].lost = true
	s.step_all(PackedInt32Array([0, 0, 0]))
	_check(s.winner == -1, "two still standing: no winner yet")
	s.aim[0] = 2
	_check(s._target(0, PackedByteArray([1, 1, 0])) == 1 and s.aim[0] == 2, "a board that's out is passed over")
	s.boards[1].lost = true
	s.step_all(PackedInt32Array([0, 0, 0]))
	_check(s.winner == 0 and s.won(0) and not s.won(1), "the last team standing wins")
	var tie := SimState.create(8, false, null, PackedInt32Array([0, 1, 2]))
	for b in tie.boards:
		b.lost = true
	tie.step_all(PackedInt32Array([0, 0, 0]))
	_check(tie.is_draw() and tie.winner == 3 and not tie.won(0), "all out at once is a draw")


## A match format 1 can't hold is written as format 2, and reads back as the same game, here
## and in Rust. A standard 1v1 stays format 1.
func _test_replays() -> void:
	var six := SimRules.standard()
	six.colors = 6
	for c: Array in [[[0, 1, 2], null], [[0, 0, 1, 1], six], [[0, 1], six], [[0, 1], null]]:
		var teams := PackedInt32Array(c[0])
		var rules: SimRules = c[1]
		var rng := RandomNumberGenerator.new()
		rng.seed = teams.size()
		var ticks: Array = []
		var masks: Array = []
		for p in teams.size():
			var t := PackedInt64Array()
			var m := PackedInt32Array()
			for k in 200:
				t.append(k * 37 + p)
				m.append(SimConst.target(rng.randi() % 5, rng.randi() % 12) | (SimConst.SWAP if k % 2 else 0))
			ticks.append(t)
			masks.append(m)
		var r := Replay.build(77, false, [[Replay.OP_GARBAGE, teams.size() - 1, 4, 2]], ticks, masks, 200 * 37 + 10, teams, rules)
		var bytes := r.encode()
		var name := "%s on %s rules" % [Array(teams), "standard" if rules == null else "six-colour"]
		var format := 1 if teams.size() == 2 and rules == null else 2
		var back := Replay.decode(bytes)
		_check(bytes[4] == format and back.error == "" and back.teams == teams and back.verify() == ""
				and back.final_state.checksum() == r.final_state.checksum(), "%s: format %d, reads back and verifies (%s)" % [name, format, back.error])
		if RustState.available():
			var why: String = ClassDB.instantiate(RustState.CLASS).verify_replay(bytes)
			_check(why == "", "%s: Rust verifies GDScript's replay (%s)" % [name, why])
		else:
			_check(true, "no Rust to verify with")
