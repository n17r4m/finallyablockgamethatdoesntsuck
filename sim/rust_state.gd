class_name RustState
extends SimState
## The game running on the Rust rules (rust/sim), through the RustSim extension class.
##
## Stepping, copying and hashing all happen in Rust. boards holds ordinary SimBoards for the
## renderers and CPU players to read, filled in by refresh_view(). They're a picture of the
## state, so writing to them changes nothing, and they're stale until the next refresh.

const CLASS := "RustSim"

var _sim: RefCounted


## False if the extension isn't in this build, holds different rules from this one, or is
## too old to take a ruleset.
static func available() -> bool:
	if not ClassDB.can_instantiate(CLASS):
		return false
	var sim: RefCounted = ClassDB.instantiate(CLASS)
	return sim.rules_version() == SimConst.RULES_VERSION and sim.has_method("reset_seated")


## A match on the Rust rules. match_rules must be valid; null plays the standard rules.
## seat_teams as SimState.create's.
static func make(game_seed: int, solo_mode := false, match_rules: SimRules = null, seat_teams := PackedInt32Array()) -> RustState:
	var s := RustState.new()
	s.solo = solo_mode
	s.rules = match_rules if match_rules else SimRules.shared_standard()
	if not seat_teams.is_empty():
		s._seat(seat_teams)
	s._sim = ClassDB.instantiate(CLASS)
	var rule_bytes := match_rules.encode() if match_rules else PackedByteArray()
	if not s._sim.reset_seated(game_seed, solo_mode, rule_bytes, PackedByteArray(Array(s.teams))):
		push_error("rust/sim refused a match GDScript accepted: %s %s" % [match_rules.validate() if match_rules else "", s.teams])
	for p in s.teams.size():
		var b := SimBoard.new()
		b.rules = s.rules
		s.boards.append(b)
	s.refresh_view()
	return s


func step(input0: int, input1: int) -> void:
	if boards.size() != 2:
		super.step(input0, input1) # reaches step_all
		return
	winner = _sim.step(input0, input1)
	tick += 1


func step_all(inputs: PackedInt32Array) -> void:
	winner = _sim.step_all(inputs)
	tick += 1


## The copy shares boards: they only ever show the state that's live now, and rollback
## snapshots are never read until one becomes live and is refreshed.
func copy() -> SimState:
	var s := RustState.new()
	s.tick = tick
	s.solo = solo
	s.winner = winner
	s.rules = rules
	s.teams = teams
	s.team_count = team_count
	s.boards = boards
	s._sim = _sim.copy()
	return s


func checksum() -> int:
	return _sim.checksum()


func canonical_bytes() -> PackedByteArray:
	return _sim.canonical_bytes()


func refresh_view() -> void:
	if boards.size() > 2:
		aim = _sim.aim()
	for p in boards.size():
		var fields: Array = _sim.board_fields(p)
		var b := boards[p]
		for i in fields.size():
			b.set(SimBoard.STATE[i], fields[i])


## The hash input rebuilt from what readers see. If it equals canonical_bytes(), the
## picture is complete and every field is in the right place.
func view_bytes() -> PackedByteArray:
	return super.canonical_bytes()
