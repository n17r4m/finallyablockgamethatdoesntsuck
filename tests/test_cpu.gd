extends SceneTree
## CPU soak: each level plays alone for a while, then hard vs easy plays a match.
## Checks the CPU actually clears/chains and stays within a frame budget.
##   godot --headless --path . -s tests/test_cpu.gd

const TPF := SimConst.TICKS_PER_FRAME
const SOLO_FRAMES := 60 * 90 # 90 s
const MATCH_FRAMES := 60 * 300 # 5 min cap

var _failed := 0
var _ran := 0


func _init() -> void:
	for name: String in CpuPlayer.OPPONENTS:
		_solo(name, "hard")
	_solo("Overmind", "easy")
	_ladder("Overmind", "max", "easy", 4)
	# A script error skips checks rather than failing them; count them.
	var expected := CpuPlayer.OPPONENTS.size() * 2 + 2 + 1
	_failed += expected - _ran
	print("PASS" if _failed == 0 else "FAIL (%d)" % _failed)
	quit(0 if _failed == 0 else 1)


func _check(ok: bool, what: String) -> void:
	_ran += 1
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_failed += 1


func _solo(name: String, level: String) -> void:
	var s := SimState.create(7, true)
	var cpu := CpuPlayer.opponent(name, level, 1)
	var b := s.boards[0]
	var best_chain := 1
	var swaps := 0
	var usec := 0
	var worst := 0
	var frames := 0
	for f in SOLO_FRAMES:
		if s.winner != -1:
			break
		var t0 := Time.get_ticks_usec()
		var input := cpu.next_input(b)
		var dt := Time.get_ticks_usec() - t0
		usec += dt
		worst = maxi(worst, dt)
		frames += 1
		if input & SimConst.SWAP:
			swaps += 1
		for t in TPF:
			s.step(input, 0)
			best_chain = maxi(best_chain, b.chain_n)
	var avg := float(usec) / frames
	level = "%s/%s" % [name, level]
	print("  %-15s %3ds alive  score %5d  swaps %4d  best chain x%d  think avg %.0f us, worst %.1f ms" % [
			level, frames / 60, b.score, swaps, best_chain, avg, worst / 1000.0])
	_check(b.score > 0 and swaps > 0, "%s CPU swaps and clears" % level)
	_check(avg < 2000.0, "%s CPU thinks in under 2 ms/frame on average" % level)


## Same personality, higher level should win most games (sides alternate).
func _ladder(name: String, hi: String, lo: String, games: int) -> void:
	var wins := 0
	for g in games:
		var s := SimState.create(11 + g)
		var flip := g % 2 == 1
		var a := CpuPlayer.opponent(name, lo if flip else hi, 2 * g + 1)
		var b := CpuPlayer.opponent(name, hi if flip else lo, 2 * g + 2)
		var f := 0
		while f < MATCH_FRAMES and s.winner == -1:
			var ia := a.next_input(s.boards[0])
			var ib := b.next_input(s.boards[1])
			for t in TPF:
				s.step(ia, ib)
			f += 1
		if s.winner == (1 if flip else 0):
			wins += 1
	_check(wins >= games - 1, "%s %s beats %s %s in %d of %d" % [name, hi, name, lo, wins, games])
