extends SceneTree
## Deterministic sim scenarios. Board rows are counted from the bottom (row 0).
##   godot --headless --path . -s tests/test_sim.gd

const W := SimConst.W
const ROWS := SimConst.ROWS
const EXPECTED_CHECKS := 17
const LONG := SimConst.TICK_HZ * 8 # long enough for any scenario here to play out
const CRACK_LONG := LONG * 3 # cracks run in bullet time

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
	_test_countdown_freezes_all_but_cursor()
	_test_top_out_grace()
	_test_crack_reveals_cell_by_cell()
	_test_story_chain_off_cracked_garbage()
	_test_crack_ripples_from_impact()
	_test_bullet_time()
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
	s.tick = SimConst.COUNTDOWN_TICKS
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
	for t in CRACK_LONG:
		s.step(0, 0)
		flashed = flashed or b.st[_idx(5, 0)] == SimBoard.MATCHED
	var bottom_panels := true
	for x in W:
		bottom_panels = bottom_panels and b.gid[_idx(x, 0)] == 0 and b.color[_idx(x, 0)] != 0
	_check(landed, "6x2 slab lands on the floor")
	_check(flashed and bottom_panels and b.gid[_idx(0, 1)] != 0,
			"touching match flashes the slab, turns its bottom row into panels, 6x1 remains on top")


func _test_countdown_freezes_all_but_cursor() -> void:
	var s := SimState.create(1)
	var b := s.boards[0]
	var before := b.color.duplicate()
	s.step(SimConst.RIGHT | SimConst.SWAP, 0)
	_run(s, SimConst.COUNTDOWN_TICKS - 2)
	_check(b.cursor_x == 3 and b.color == before and b.rise == 0, "countdown: cursor moves, swap/rise don't")


func _test_top_out_grace() -> void:
	var s := _empty()
	var b := s.boards[0]
	b.stop_t = 0
	for row in SimConst.H:
		b.put(0, row, 1 + row % 2)
	_run(s, SimConst.HEALTH_TICKS - 10)
	var survived := not b.lost and s.winner == -1
	_run(s, 20)
	_check(survived and b.lost and s.winner == 1, "topped out: survives the grace period, then loses")


## A 6x1 slab resting on two full rows, cracked by a match on top of it.
func _cracking_slab() -> SimState:
	var s := _empty()
	var b := s.boards[0]
	for x in W:
		b.put(x, 0, 1 + x % 2)
		b.put(x, 1, 2 - x % 2 + 2)
	b.receive_garbage(PackedInt32Array([SimConst.slab(6, 1)]))
	_run(s, LONG)
	for x in 3:
		b.put(x, 3, 5)
	_run(s, 2)
	return s


func _test_crack_reveals_cell_by_cell() -> void:
	var s := _cracking_slab()
	var b := s.boards[0]
	var promised := PackedByteArray()
	for x in W:
		promised.append(b.reveal[_idx(x, 2)])
	var partial := false
	var early_release := false
	for t in LONG:
		s.step(0, 0)
		var shown := 0
		for e in BoardView.blocks(b):
			if e.gid == 0 and absf(e.pos.y - (SimConst.H - 3)) < 0.01 and b.gid[_idx(int(e.pos.x), 2)] != 0:
				shown += 1
		partial = partial or (shown > 0 and shown < W)
		early_release = early_release or (shown < W and b.gid[_idx(0, 2)] == 0 and b.color[_idx(0, 2)] != 0 and t < 100)
		if b.gid[_idx(W - 1, 2)] == 0:
			break
	var landed := PackedByteArray()
	for x in W:
		landed.append(b.color[_idx(x, 2)])
	_check(partial and not early_release, "cracking garbage reveals its panels one at a time")
	_check(promised == landed and not promised.has(0), "revealed colours are fixed when the crack starts")


## The story: near the top, crack the slab above, read the colours as they're
## revealed, rearrange below so a revealed panel drops into a match -> chain.
func _test_story_chain_off_cracked_garbage() -> void:
	var s := _cracking_slab()
	var b := s.boards[0]
	var c := b.reveal[_idx(4, 2)]
	var others := [1, 2, 3, 4, 5].filter(func(v: int) -> bool: return v != c)
	var a: int = others[0]
	var d: int = others[1]
	# Rearrange underneath while it cracks: a gap under x=4 flanked by two of its colour.
	var row0 := [a, d, a, d, a, d]
	var row1 := [d, a, c, c, 0, a]
	for x in W:
		b.color[_idx(x, 0)] = row0[x]
		b.color[_idx(x, 1)] = row1[x]
	b.need_support = true
	b.need_scan = true
	var hung_before_drop := 0
	for t in CRACK_LONG:
		s.step(0, 0)
		if b.gid[_idx(4, 2)] == 0 and b.st[_idx(4, 2)] == SimBoard.HOVER:
			hung_before_drop += 1
	_check(b.best_chain >= 2 and hung_before_drop > 0 and b.sent >= W,
			"revealed panel hangs %d ms, drops into the gap, and the match is a chain (x%d, %d cells sent)" % [
			hung_before_drop * 1000 / SimConst.TICK_HZ, b.best_chain, b.sent])


## Bottom-row reveal times for a cracking slab, by column: ticks until each shows.
func _reveal_times(b: SimBoard, row: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for x in W:
		var i := _idx(x, row)
		out.append(b.tm[i] - (b.aux[i] & 0xFFFF))
	return out


func _test_crack_ripples_from_impact() -> void:
	# Match on top-left of a 6x2 slab: the bottom row must open nearest-first, left to right.
	var s := _empty()
	var b := s.boards[0]
	for x in W:
		b.put(x, 0, 1 + x % 2)
	b.receive_garbage(PackedInt32Array([SimConst.slab(6, 2)]))
	_run(s, LONG)
	for x in 3:
		b.put(x, 3, 5)
	_run(s, 2)
	var top_hit := _reveal_times(b, 1)
	var ok_order := true
	for x in range(1, W):
		ok_order = ok_order and top_hit[x] >= top_hit[x - 1]
	var bottom_before_far_top := top_hit[0] < b.tm[_idx(5, 2)] - (b.aux[_idx(5, 2)] & 0xFFFF)
	_check(ok_order and bottom_before_far_top,
			"crack ripples out from the impact; the bottom row near it opens before far shell cells (%s)" % top_hit)


## While garbage cracks, the world slows but the player doesn't: swaps finish in
## real time while the crack's timers crawl; then the clock eases back.
func _test_bullet_time() -> void:
	var s := _cracking_slab()
	var b := s.boards[0]
	_run(s, SimConst.TIME_RAMP * (SimConst.TIME_UNIT - SimConst.TIME_SLOW) + 10)
	var slowed := b.time_rate == SimConst.TIME_SLOW
	var crack_tm := b.tm[_idx(5, 2)]
	b.cursor_x = 0
	b.cursor_y = ROWS - 1
	s.step(SimConst.SWAP, 0)
	_run(s, SimConst.SWAP_TICKS)
	var swap_done := b.st[_idx(0, 0)] == SimBoard.NORMAL and b.st[_idx(1, 0)] == SimBoard.NORMAL
	var crack_advanced := crack_tm - b.tm[_idx(5, 2)]
	_run(s, CRACK_LONG)
	_check(slowed and swap_done and crack_advanced < SimConst.SWAP_TICKS * 0.5 and b.time_rate == SimConst.TIME_UNIT,
			"bullet time: swap takes %d ticks while the crack advances %d; clock back to normal after" % [
			SimConst.SWAP_TICKS, crack_advanced])
