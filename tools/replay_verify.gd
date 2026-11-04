extends SceneTree
## Re-simulates replay files and reports whether each one is genuine.
##   godot --headless --path . -s tools/replay_verify.gd -- FILE [FILE...]

const NAMES := {-1: "unfinished", 0: "player 1 won", 1: "player 2 won", 2: "draw"}


func _init() -> void:
	var failed := 0
	var files := OS.get_cmdline_user_args()
	for path in files:
		var r := Replay.decode(FileAccess.get_file_as_bytes(path))
		var err := r.error if r.error != "" else r.verify()
		if err != "":
			failed += 1
			print("FAIL %s: %s" % [path, err])
		else:
			print("ok   %s: %.1f s, %s, inputs %d/%d" % [path, float(r.end_tick) / r.tick_hz,
					NAMES[r.final_state.winner], r.ticks[0].size(), r.ticks[1].size()])
	print("PASS" if failed == 0 and not files.is_empty() else "FAIL")
	quit(0 if failed == 0 and not files.is_empty() else 1)
