class_name SimState
extends RefCounted
## The entire deterministic game: every seat's well, the tick counter and the result.
##
## A match seats any number of players, each with a well, on two or more teams. Garbage a
## board sends goes to one board on another team that was still playing when the tick began,
## taking turns round the table. A board that tops out stops; a team is out when all its boards
## are, and the last team standing wins. 1v1 is the two-seat case and plays exactly as before.

var tick := 0
var boards: Array[SimBoard] = []
var solo := false # practice: only board 0 plays
## -1 while playing, then the winning team, or the team count for a draw (2 in a 1v1).
var winner := -1
## The match's rules: the countdown, and what each board starts with. Not hashed.
var rules: SimRules
## Each seat's team, numbered from 0 with none left out. Part of the match, like the rules:
## never changes, not hashed. Copies share it.
var teams := PackedInt32Array([0, 1])
var team_count := 2
## Per board, the seat its next garbage tries first. Hashed when there are more than two boards,
## the only time it can matter.
var aim := PackedInt32Array([1, 0])

var _inputs := PackedInt32Array([0, 0]) # step()'s two inputs, without a new array each tick


## A match. match_rules must be valid; null plays the standard rules. seat_teams must pass
## teams_error(); empty is a 1v1.
static func create(game_seed: int, solo_mode := false, match_rules: SimRules = null, seat_teams := PackedInt32Array()) -> SimState:
	var s := SimState.new()
	s.solo = solo_mode
	s.rules = match_rules if match_rules else SimRules.shared_standard()
	if not seat_teams.is_empty():
		s._seat(seat_teams)
	# Same seed for every well so the start is fair.
	for p in s.teams.size():
		s.boards.append(SimBoard.create(game_seed, s.rules))
	return s


## Why these can't be a match's teams, or "" if they can: two to MAX_SEATS seats, teams
## numbered from 0 with none empty, and at least two of them.
static func teams_error(seat_teams: PackedInt32Array) -> String:
	if seat_teams.size() < 2 or seat_teams.size() > SimConst.MAX_SEATS:
		return "%d seats; a match has 2 to %d" % [seat_teams.size(), SimConst.MAX_SEATS]
	var count := 0
	for t in seat_teams:
		if t < 0 or t >= seat_teams.size():
			return "team %d" % t
		count = maxi(count, t + 1)
	if count < 2:
		return "one team"
	for t in count:
		if not t in seat_teams:
			return "no seat on team %d" % t
	return ""


func _seat(seat_teams: PackedInt32Array) -> void:
	assert(teams_error(seat_teams) == "", teams_error(seat_teams))
	teams = seat_teams
	team_count = 0
	for t in teams:
		team_count = maxi(team_count, t + 1)
	aim = PackedInt32Array()
	for p in teams.size():
		aim.append((p + 1) % teams.size())


func seats() -> int:
	return boards.size()


## A 1v1's step: both seats' inputs.
func step(input0: int, input1: int) -> void:
	_inputs[0] = input0
	_inputs[1] = input1
	step_all(_inputs)


## One tick, with an input for every seat.
func step_all(inputs: PackedInt32Array) -> void:
	if winner == -1:
		var live := tick >= rules.countdown
		var n := boards.size()
		if solo:
			boards[0].step(inputs[0], live)
			boards[0].outbox.clear()
		else:
			var playing := PackedByteArray()
			playing.resize(n)
			for p in n:
				playing[p] = 0 if boards[p].lost else 1
				boards[p].step(inputs[p], live)
			for p in n:
				if not boards[p].outbox.is_empty():
					var to := _target(p, playing)
					if to != -1:
						boards[to].receive_garbage(boards[p].outbox)
					boards[p].outbox.clear()
		_judge()
	tick += 1


## Who board p's garbage goes to: the first board on another team, from p's aim round the
## table, that was playing when the tick began.
func _target(p: int, playing: PackedByteArray) -> int:
	var n := boards.size()
	for k in n:
		var q := (aim[p] + k) % n
		if teams[q] != teams[p] and playing[q] == 1:
			aim[p] = (q + 1) % n
			return q
	return -1


## The match ends when at most one team has a board still playing. In practice board 1 never
## plays, so it stands until board 0 falls.
func _judge() -> void:
	var standing := -1
	var count := 0
	var seen := 0 # teams with a board still playing, as bits
	for p in boards.size():
		if not boards[p].lost and not seen & (1 << teams[p]):
			seen |= 1 << teams[p]
			standing = teams[p]
			count += 1
	if count <= 1:
		winner = standing if count == 1 else team_count


## Whether board p's team won.
func won(p: int) -> bool:
	return winner != -1 and winner != team_count and teams[p] == winner


func is_draw() -> bool:
	return winner == team_count


## Brings boards up to date for readers. They always are here; see RustState.
func refresh_view() -> void:
	pass


func copy() -> SimState:
	var s := SimState.new()
	s.tick = tick
	s.solo = solo
	s.winner = winner
	s.rules = rules
	s.teams = teams
	s.team_count = team_count
	s.aim = aim.duplicate()
	s.boards.clear()
	for b in boards:
		s.boards.append(b.copy())
	return s


func checksum() -> int:
	return SimConst.hash64(canonical_bytes())


## The exact bytes the state hash covers: tick i64, solo u8, winner i64, then each board, then
## with more than two boards each one's aim as i64.
func canonical_bytes() -> PackedByteArray:
	var out := StreamPeerBuffer.new()
	out.put_64(tick)
	out.put_u8(1 if solo else 0)
	out.put_64(winner)
	for b in boards:
		b.write_canonical(out)
	if boards.size() > 2:
		for a in aim:
			out.put_64(a)
	return out.data_array
