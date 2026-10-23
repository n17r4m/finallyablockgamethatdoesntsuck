extends SceneTree
## Round-robin of CPU personalities, sides alternating. For tuning styles and,
## later, harvesting labelled positions for learned weights.
##   godot --headless --path . -s tools/league.gd -- LEVEL GAMES_PER_PAIR [ROW]
## ROW limits output to pairings of that roster index (run several in parallel).


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var level: String = args[0] if args.size() > 0 else "hard"
	var games := int(args[1]) if args.size() > 1 else 6
	var names: Array = CpuPlayer.OPPONENTS.keys()
	var rows: Array = range(names.size()) if args.size() < 3 else [int(args[2])]
	for i: int in rows:
		for j in range(i + 1, names.size()):
			var wins := [0, 0, 0]
			for g in games:
				var flip := g % 2 == 1
				var winner := _play(names[j] if flip else names[i], names[i] if flip else names[j], level, 500 + g)
				if flip and winner < 2:
					winner = 1 - winner
				wins[winner] += 1
			print("%-9s vs %-9s %d-%d  (%d draw/timeout)" % [names[i], names[j], wins[0], wins[1], wins[2]])
	quit()


## Returns 0/1 for the winning side, 2 for draw or 5-minute timeout.
func _play(a_name: String, b_name: String, level: String, game_seed: int) -> int:
	var s := SimState.create(game_seed)
	var a := CpuPlayer.opponent(a_name, level, game_seed * 2)
	var b := CpuPlayer.opponent(b_name, level, game_seed * 2 + 1)
	var f := 0
	while f < 60 * 300 and s.winner == -1:
		var ia := a.next_input(s.boards[0])
		var ib := b.next_input(s.boards[1])
		for t in SimConst.TICKS_PER_FRAME:
			s.step(ia, ib)
		f += 1
	return s.winner if s.winner >= 0 else 2
