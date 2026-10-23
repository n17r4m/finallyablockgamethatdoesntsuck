extends SceneTree
## Deterministic sim scenarios. Board rows are counted from the bottom (row 0).
##   godot --headless --path . -s tests/test_sim.gd

const W := SimConst.W
const ROWS := SimConst.ROWS
const EXPECTED_CHECKS := 10
const LONG := SimConst.TICK_HZ * 8 # long enough for any scenario here to play out

var _failed := 0
var _ran := 0


func _init() -> void:
	_test_combo_sends_garbage(4, [SimConst.slab(3, 1)])
	_test_combo_sends_garbage(5, [SimConst.slab(4, 1)]) # L: vertical 3 + horizontal 3 sharing a corner
	_test_chain(false, [SimConst.slab(6, 1)], 2)
	_test_chain(true, [SimConst.slab(6, 2)], 3)
	_test_swap_animates_with_depth()
	_test_panel_hovers_then_falls()
	_test_garbage_lands_as_one_slab()
	_test_match_converts_garbage_bottom_row()
	_failed += EXPECTED_CHECKS - _ran
	print("PASS" if _failed == 0 else "FAIL (%d)" % _failed)
	quit(0 if _failed == 0 else 1)


func _check(ok: bool, what: String) -> void:
	_ran += 1
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_failed += 1


func _empty() -> SimState:
	var s := SimState.create(1)
	for b in s.boards:
		b.clear_all()
		b.stop_t = 1 << 30 # freeze the rise so layouts stay put
	return s


func _run(s: SimState, ticks: int) -> void:
	for t in ticks:
		s.step(0, 0)


func _idx(x: int, row: int) -> int:
	return (ROWS - 1 - row) * W + x


func _test_combo_sends_garbage(n: int, expect: Array) -> void:
	var s := _empty()
	var b := s.boards[0]
	if n == 4:
		for x in 4:
			b.put(x, 0, 1)
	else:
		for x in 3:
			b.put(x, 0, 1)
		b.put(0, 1, 1)
		b.put(0, 2, 1)
	_run(s, 1)
	_check(Array(s.boards[1].gar_q) == expect, "combo of %d sends %s" % [n, Array(s.boards[1].gar_q)])


## Clearing the 1s drops a 2 into a row of 2s (chain 2); with `third`, clearing
## those drops 3s next to another 3 (chain 3). Garbage goes out when it ends.
func _test_chain(third: bool, expect: Array, expect_max: int) -> void:
	var s := _empty()
	var b := s.boards[0]
	for x in 3:
		b.put(x, 0, 1)
	b.put(3, 0, 2)
	b.put(4, 0, 2)
	b.put(2, 1, 2)
	b.put(3, 1, 3)
	b.put(4, 1, 3)
	if third:
		b.put(5, 0, 3)
	var max_chain := 1
	var sent := []
	for t in LONG:
		s.step(0, 0)
		max_chain = maxi(max_chain, b.chain_n)
		sent.append_array(Array(s.boards[1].gar_q))
		s.boards[1].gar_q.clear()
	_check(max_chain == expect_max and sent == expect and b.chain_n == 1,
			"chain reaches %d and sends %s when it ends (got %d, %s)" % [expect_max, expect, max_chain, sent])


func _test_swap_animates_with_depth() -> void:
	var s := _empty()
	var b := s.boards[0]
	b.put(0, 0, 1)
	b.put(1, 0, 2)
	b.cursor_x = 0
	b.cursor_y = ROWS - 1
	_run(s, 1)
	s.step(SimConst.SWAP, 0)
	_run(s, SimConst.SWAP_TICKS / 2)
	var v := BoardView.blocks(b)
	var right: Dictionary = v.filter(func(e: Dictionary) -> bool: return e.color == 1)[0]
	var left: Dictionary = v.filter(func(e: Dictionary) -> bool: return e.color == 2)[0]
	_check(b.color[_idx(1, 0)] == 1 and right.pos.z > 0.3 and left.pos.z < -0.3
			and absf(right.pos.x - 0.5) < 0.1 and absf(left.pos.x - 0.5) < 0.1,
			"mid-swap: panels cross at x=0.5, one in front (z %.2f), one behind (z %.2f)" % [right.pos.z, left.pos.z])
	_run(s, SimConst.SWAP_TICKS)
	_check(b.st[_idx(0, 0)] == SimBoard.NORMAL and b.st[_idx(1, 0)] == SimBoard.NORMAL, "swap settles")


func _test_panel_hovers_then_falls() -> void:
	var s := _empty()
	var b := s.boards[0]
	b.put(0, 0, 1)
	b.put(1, 1, 2) # nothing under it
	_run(s, 2)
	var hovering := b.st[_idx(1, 1)] == SimBoard.HOVER
	_run(s, SimConst.HOVER_TICKS + SimConst.FALL_TICKS + 2)
	_check(hovering and b.color[_idx(1, 0)] == 2 and b.color[_idx(1, 1)] == 0,
			"unsupported panel hovers, then falls and lands")


func _test_garbage_lands_as_one_slab() -> void:
	var s := _empty()
	var b := s.boards[0]
	b.put(2, 0, 2) # a single block for the slab to land on
	b.receive_garbage(PackedInt32Array([SimConst.slab(4, 1)]))
	_run(s, LONG)
	var g := b.gid[_idx(0, 1)]
	_check(g != 0 and b.gid[_idx(3, 1)] == g and b.gid[_idx(4, 1)] == 0 and b.color[_idx(0, 0)] == 0,
			"4-wide slab falls as a unit and rests on one block")


func _test_match_converts_garbage_bottom_row() -> void:
	var s := _empty()
	var b := s.boards[0]
	b.receive_garbage(PackedInt32Array([SimConst.slab(6, 2)]))
	_run(s, LONG)
	var landed := b.gid[_idx(0, 0)] != 0 and b.gid[_idx(0, 1)] != 0
	for x in 3:
		b.put(x, 2, 3) # three in a row sitting on the slab
	var flashed := false
	for t in LONG:
		s.step(0, 0)
		flashed = flashed or b.st[_idx(5, 0)] == SimBoard.MATCHED
	var bottom_panels := true
	for x in W:
		bottom_panels = bottom_panels and b.gid[_idx(x, 0)] == 0 and b.color[_idx(x, 0)] != 0
	_check(landed, "6x2 slab lands on the floor")
	_check(flashed and bottom_panels and b.gid[_idx(0, 1)] != 0,
			"touching match flashes the slab, turns its bottom row into panels, 6x1 remains on top")
