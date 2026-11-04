extends SceneTree
## What the sim really costs: two CPUs play busy boards, timing only the sim's own work.
## Run on an idle machine. Boards in test_netcode are near-idle, so its figure reads low.
##   godot --headless --path . -s tools/bench_sim.gd [-- --minutes=3]

const TPF := SimConst.TICKS_PER_FRAME


func _init() -> void:
	var minutes := 3
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--minutes="):
			minutes = a.trim_prefix("--minutes=").to_int()
	var budget := SimConst.TICK_HZ * 60 * minutes
	var frames := PackedInt64Array()
	var copies := PackedInt64Array()
	var rollbacks := PackedInt64Array()
	var think := 0
	var ticks := 0
	var games := 0
	while ticks < budget:
		games += 1
		var s := SimState.create(977 + games)
		var c0 := CpuPlayer.opponent("Overmind", "hard", games)
		var c1 := CpuPlayer.opponent("Architect", "hard", games + 1)
		while s.winner == -1 and ticks < budget:
			var t0 := Time.get_ticks_usec()
			var i0 := c0.next_input(s.boards[0])
			var i1 := c1.next_input(s.boards[1])
			var t1 := Time.get_ticks_usec()
			think += t1 - t0
			for _k in TPF:
				s.step(i0, i1)
			frames.append(Time.get_ticks_usec() - t1)
			ticks += TPF
			if frames.size() % 30 == 0: # the deepest rollback a session allows, from here
				var t2 := Time.get_ticks_usec()
				var snap := s.copy()
				var t3 := Time.get_ticks_usec()
				copies.append(t3 - t2)
				for _k in RollbackSession.MAX_AHEAD + TPF:
					snap.step(i0, i1)
				rollbacks.append(Time.get_ticks_usec() - t3)
	var mean := 0.0
	for f in frames:
		mean += f
	mean /= frames.size()
	print("%d games, %d ticks at %d Hz" % [games, ticks, SimConst.TICK_HZ])
	print("sim: %.1f us/tick (two boards), %.1f%% of a core per match" % [mean / TPF, mean * 60.0 / 10000.0])
	print("frame (%d ticks) ms:  %s" % [TPF, _pct(frames)])
	print("snapshot ms:          %s" % _pct(copies))
	print("worst rollback (%d ticks) ms, budget 16.7: %s" % [RollbackSession.MAX_AHEAD + TPF, _pct(rollbacks)])
	print("CPU players: %.2f ms per frame" % (think / 1000.0 / frames.size()))
	quit()


func _pct(a: PackedInt64Array) -> String:
	a.sort()
	return "p50 %.2f  p99 %.2f  max %.2f" % [a[a.size() / 2] / 1000.0, a[a.size() * 99 / 100] / 1000.0, a[-1] / 1000.0]
