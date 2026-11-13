extends SceneTree
## Sound: every tone is audible and doesn't clip, and Ears hear a CPU game's swaps, matches,
## pops, chains, landings and garbage, once each, at the frame rate the match runs.
##   godot --headless --path . -s tests/test_sfx.gd

const EXPECTED_CHECKS := 32
var _failed := 0
var _ran := 0


func _init() -> void:
	_test_tones()
	_test_ears_hear_a_game()
	_test_a_frame_without_change_is_silent()
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


func _test_tones() -> void:
	for n in Tones.names():
		var w := Tones.get_stream(n)
		var peak := 0
		for i in w.data.size() / 2:
			peak = maxi(peak, absi(w.data.decode_s16(i * 2)))
		_check(peak > 3000 and peak < 32767, "%s is audible and doesn't clip (peak %d)" % [n, peak])
	_check(Tones.get_stream("pop") == Tones.get_stream("pop"), "tones are made once")


func _test_ears_hear_a_game() -> void:
	var heard := {}
	for game_seed in [3, 4]:
		var s := SimState.create(game_seed)
		var cpus := [CpuPlayer.opponent("Architect", "hard", game_seed), CpuPlayer.opponent("Brawler", "hard", game_seed + 1)]
		var ears := [Ears.new(), Ears.new()]
		while s.winner == -1 and s.tick < SimConst.TICK_HZ * 75:
			var in0: int = cpus[0].next_input(s.boards[0])
			var in1: int = cpus[1].next_input(s.boards[1])
			for k in SimConst.TICKS_PER_FRAME:
				s.step(in0, in1)
			for p in 2:
				for e: Array in ears[p].hear(s.boards[p]):
					heard[e[0]] = heard.get(e[0], 0) + 1
					if e[0] == "pop":
						heard["top_pop"] = maxi(heard.get("top_pop", 0), e[1])
	print("  heard ", heard)
	for n in ["move", "swap", "land", "match", "chain", "pop", "crack", "reveal", "thud"]:
		_check(heard.get(n, 0) > 0, "a CPU game makes a %s" % n)
	_check(heard.get("pop", 0) >= 3 * (heard.get("match", 0) + heard.get("chain", 0)), "every matched panel pops once or more")
	_check(heard.get("top_pop", 0) >= 2, "a run of pops climbs the scale")


func _test_a_frame_without_change_is_silent() -> void:
	var s := SimState.create(9)
	var ears := Ears.new()
	_check(ears.hear(s.boards[0]).is_empty(), "the first frame only listens")
	_check(ears.hear(s.boards[0]).is_empty(), "nothing changed, nothing heard")
	var copy := s.copy()
	_check(ears.hear(copy.boards[0]).is_empty(), "a rollback copy of the same moment is silent")
	s.boards[0].lost = true
	_check(ears.hear(s.boards[0]) == [["lost"]], "losing is heard")
	_check(ears.hear(s.boards[0]).is_empty(), "and only once")
	var sfx := Sfx.new()
	_check(Sfx._note(0) == 0 and Sfx._note(99) == Sfx.SCALE[-1], "long runs stay at the top of the scale")
	sfx.free()
