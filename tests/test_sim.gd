extends SceneTree
## Deterministic sim scenarios.
##   godot --headless --path . -s tests/test_sim.gd

const W := SimConst.W
const H := SimConst.H

const EXPECTED_CHECKS := 4

var _failed := 0
var _ran := 0


func _init() -> void:
	_test_combo_sends_garbage(4, [3])
	_test_combo_sends_garbage(5, [4]) # L-shape: vertical 3 + horizontal 3 sharing a corner
	_test_garbage_lands_as_one_slab()
	_test_match_converts_touching_garbage()
	_failed += EXPECTED_CHECKS - _ran
	print("PASS" if _failed == 0 else "FAIL (%d)" % _failed)
	quit(0 if _failed == 0 else 1)


func _check(ok: bool, what: String) -> void:
	_ran += 1
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_failed += 1


func _empty_state() -> SimState:
	var s := SimState.create(1)
	for b in s.boards:
		b.cells.fill(0)
	return s


func _put(b: SimBoard, x: int, y: int, c: int) -> void:
	b.cells[y * W + x] = c
	b.unsettled = true


func _run(s: SimState, ticks: int) -> void:
	for t in ticks:
		s.step(0, 0)


func _test_combo_sends_garbage(n: int, expect: Array) -> void:
	var s := _empty_state()
	var b := s.boards[0]
	if n == 4: # horizontal 4 on the floor
		for x in 4:
			_put(b, x, H - 1, 1)
	else: # L: floor row x0..2, column x0 up two more
		for x in 3:
			_put(b, x, H - 1, 1)
		_put(b, 0, H - 2, 1)
		_put(b, 0, H - 3, 1)
	_run(s, SimConst.FALL_TICKS + 1)
	_check(Array(s.boards[1].gar_q) == expect,
			"combo of %d sends %s (got %s)" % [n, expect, Array(s.boards[1].gar_q)])


func _test_garbage_lands_as_one_slab() -> void:
	var s := _empty_state()
	_put(s.boards[0], 2, H - 1, 2) # a single block for the slab to land on
	s.boards[0].receive_garbage(PackedByteArray([4]))
	_run(s, SimConst.GARBAGE_DELAY + SimConst.FALL_TICKS * (H + 2))
	var b := s.boards[0]
	var row := (H - 2) * W
	var slab := b.gid[row] != 0 and b.gid[row] == b.gid[row + 1] and b.gid[row] == b.gid[row + 3]
	_check(slab and b.gid[row + 4] == 0 and b.cells[(H - 1) * W] == 0,
			"4-wide slab falls as a unit and rests on one block")


func _test_match_converts_touching_garbage() -> void:
	var s := _empty_state()
	var b := s.boards[0]
	b.receive_garbage(PackedByteArray([6]))
	_run(s, SimConst.GARBAGE_DELAY + SimConst.FALL_TICKS * (H + 2))
	var landed := b.gid[(H - 1) * W] != 0
	# Three in a row on top of the slab.
	for x in 3:
		_put(b, x, 0, 3)
	_run(s, SimConst.FALL_TICKS * (H + 2))
	var converted := true
	for x in W:
		converted = converted and b.gid[(H - 1) * W + x] == 0 and b.cells[(H - 1) * W + x] != 0
	_check(landed and converted, "match touching garbage turns the slab back into blocks")
