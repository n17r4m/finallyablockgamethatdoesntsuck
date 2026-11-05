class_name RustState
extends SimState
## The game running on the Rust rules (rust/sim), through the RustSim extension class.
##
## Stepping, copying and hashing all happen in Rust. boards holds ordinary SimBoards for the
## renderers and CPU players to read, filled in by refresh_view(). They're a picture of the
## state, so writing to them changes nothing, and they're stale until the next refresh.

const CLASS := "RustSim"

var _sim: RefCounted


## False if the extension isn't in this build, or holds different rules from this one.
static func available() -> bool:
	if not ClassDB.can_instantiate(CLASS):
		return false
	var sim: RefCounted = ClassDB.instantiate(CLASS)
	return sim.rules_version() == SimConst.RULES_VERSION


static func make(game_seed: int, solo_mode := false) -> RustState:
	var s := RustState.new()
	s.solo = solo_mode
	s._sim = ClassDB.instantiate(CLASS)
	s._sim.reset(game_seed, solo_mode)
	s.boards.append(SimBoard.new())
	s.boards.append(SimBoard.new())
	s.refresh_view()
	return s


func step(input0: int, input1: int) -> void:
	winner = _sim.step(input0, input1)
	tick += 1


## The copy shares boards: they only ever show the state that's live now, and rollback
## snapshots are never read until one becomes live and is refreshed.
func copy() -> SimState:
	var s := RustState.new()
	s.tick = tick
	s.solo = solo
	s.winner = winner
	s.boards = boards
	s._sim = _sim.copy()
	return s


func checksum() -> int:
	return _sim.checksum()


func canonical_bytes() -> PackedByteArray:
	return _sim.canonical_bytes()


func refresh_view() -> void:
	for p in 2:
		var fields: Array = _sim.board_fields(p)
		var b := boards[p]
		for i in fields.size():
			b.set(SimBoard.STATE[i], fields[i])


## The hash input rebuilt from what readers see. If it equals canonical_bytes(), the
## picture is complete and every field is in the right place.
func view_bytes() -> PackedByteArray:
	return super.canonical_bytes()
