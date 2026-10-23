extends SceneTree
## Round-robin CPU league with JSONL logging, for comparing agents and
## harvesting labelled positions. Analyse with tools/league_report.py.
##
##   nice -n 19 godot --headless --path . -s tools/league.gd -- \
##       --agents=stochastic/balanced/hard,beam/balanced/hard,Architect:hard \
##       --games=10 --out=data/run1 [--positions] [--worker=0 --workers=2] [--seed=1000] [--start=0]
##
## Agents are "search/style/level" or roster "Name:level". Sides alternate each
## game. Each worker plays games k where k % workers == worker and appends to its
## own files: games-w<worker>.jsonl (one line per game) and, with --positions,
## positions-w<worker>.jsonl (both boards' features once a second, labelled with
## the eventual result: 1 won, 0 lost, 0.5 draw/timeout). --start=K skips games
## below K, to resume an interrupted run (possibly with a different worker count).

const MAX_FRAMES := 60 * 600 # 10 min cap; the rise speed-up should end games well before
const SAMPLE_EVERY := 60


func _init() -> void:
	var opt := {"agents": "", "games": "10", "out": "data/league", "worker": "0", "workers": "1", "seed": "1000", "start": "0"}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		opt[kv[0]] = kv[1] if kv.size() > 1 else "true"
	var agents: PackedStringArray = opt.agents.split(",", false)
	if agents.size() < 2:
		printerr("need --agents=a,b[,...]")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(opt.out)
	var worker := int(opt.worker)
	var workers := int(opt.workers)
	var games_f := FileAccess.open("%s/games-w%d.jsonl" % [opt.out, worker], FileAccess.READ_WRITE if
			FileAccess.file_exists("%s/games-w%d.jsonl" % [opt.out, worker]) else FileAccess.WRITE)
	games_f.seek_end()
	var pos_f: FileAccess = null
	if opt.has("positions"):
		var pp := "%s/positions-w%d.jsonl" % [opt.out, worker]
		pos_f = FileAccess.open(pp, FileAccess.READ_WRITE if FileAccess.file_exists(pp) else FileAccess.WRITE)
		pos_f.seek_end()

	var k := 0
	for i in agents.size():
		for j in range(i + 1, agents.size()):
			for g in int(opt.games):
				if k >= int(opt.start) and k % workers == worker:
					var flip := g % 2 == 1
					var rec := _play(agents[j] if flip else agents[i], agents[i] if flip else agents[j],
							int(opt.seed) + k, pos_f)
					rec["game"] = k
					games_f.store_line(JSON.stringify(rec))
					games_f.flush()
					print("%5d  %s vs %s -> %s in %ds" % [k, rec.a, rec.b, rec.winner, rec.frames / 60])
				k += 1
	quit()


func _play(a_spec: String, b_spec: String, game_seed: int, pos_f: FileAccess) -> Dictionary:
	var s := SimState.create(game_seed)
	var cpus: Array[CpuPlayer] = [CpuPlayer.from_spec(a_spec, game_seed * 2), CpuPlayer.from_spec(b_spec, game_seed * 2 + 1)]
	var samples: Array = []
	var f := 0
	while f < MAX_FRAMES and s.winner == -1:
		var ia := cpus[0].next_input(s.boards[0])
		var ib := cpus[1].next_input(s.boards[1])
		for t in SimConst.TICKS_PER_FRAME:
			s.step(ia, ib)
		f += 1
		if pos_f and f % SAMPLE_EVERY == 0 and s.tick > SimConst.COUNTDOWN_TICKS:
			var fs: Array = []
			for p in 2:
				var b := s.boards[p]
				fs.append(Array(cpus[p].features(cpus[p].project(b), cpus[p]._garbage_rows(b))))
			samples.append([f, fs])
	var winner := s.winner if s.winner >= 0 else 2
	if pos_f:
		for smp: Array in samples:
			for p in 2:
				var label := 0.5 if winner == 2 else (1.0 if winner == p else 0.0)
				pos_f.store_line(JSON.stringify({"seed": game_seed, "frame": smp[0], "side": p,
						"agent": a_spec if p == 0 else b_spec, "own": smp[1][p], "opp": smp[1][1 - p],
						"label": label}))
		pos_f.flush()
	var rec := {"seed": game_seed, "a": a_spec, "b": b_spec, "winner": winner, "frames": f,
			"timeout": s.winner == -1}
	for key in ["score", "sent", "best_chain", "swaps"]:
		rec[key] = [s.boards[0].get(key), s.boards[1].get(key)]
	rec["think_avg_us"] = [cpus[0].think_usec / maxi(cpus[0].think_frames, 1), cpus[1].think_usec / maxi(cpus[1].think_frames, 1)]
	rec["think_max_us"] = [cpus[0].think_usec_max, cpus[1].think_usec_max]
	return rec
