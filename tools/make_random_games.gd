extends SceneTree
## Plays fresh random games and writes them as replays, so another implementation of the rules
## can be held to games nobody recorded in advance. tests/golden locks what we thought of; this
## looks for what we didn't. Boards here go beyond real play on purpose: two-colour stacks force
## huge combos, and slabs come in shapes no combo sends.
##   godot --headless --path . -s tools/make_random_games.gd -- --dir=DIR --games=N [--seed=S] [--seconds=N]

const Rec = preload("res://tools/make_golden.gd").Rec
const HZ := SimConst.TICK_HZ
const TPF := SimConst.TICKS_PER_FRAME
const KINDS := ["chaos", "subframe", "two_colours", "garbage_rain", "cpu"]
const CPUS := ["Overmind", "Architect", "Blitz"]
const LEVELS := ["easy", "normal", "hard", "max"]

var _rng := RandomNumberGenerator.new()
var _seconds := 60
var _best_chain := 0
var _best_combo := 0
var _slabs := 0
var _bullet := 0
var _finished := 0
var _ticks := 0


func _init() -> void:
	var dir := ""
	var games := 20
	var first_seed := 1
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--dir="):
			dir = arg.get_slice("=", 1)
		elif arg.begins_with("--games="):
			games = arg.get_slice("=", 1).to_int()
		elif arg.begins_with("--seed="):
			first_seed = arg.get_slice("=", 1).to_int()
		elif arg.begins_with("--seconds="):
			_seconds = arg.get_slice("=", 1).to_int()
	if dir == "" or games < 1 or _seconds < 1:
		print("usage: -- --dir=DIR --games=N [--seed=S] [--seconds=N]")
		print("FAIL")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(dir)
	for n in games:
		var game_seed := first_seed + n
		_rng.seed = game_seed
		var kind: String = KINDS[game_seed % KINDS.size()]
		var rec: Rec = call("_" + kind, game_seed)
		var f := FileAccess.open("%s/%s_%d.fbgr" % [dir, kind, game_seed], FileAccess.WRITE)
		f.store_buffer(rec.to_replay().encode())
		f.close()
		_ticks += rec.state.tick
		_finished += 1 if rec.state.winner != -1 else 0
		for b: SimBoard in rec.state.boards:
			_best_chain = maxi(_best_chain, b.best_chain)
	print("%d games, %d ticks, %d finished; best chain %d, best combo %d, up to %d slabs in a game, %d ticks of bullet time" % [
			games, _ticks, _finished, _best_chain, _best_combo, _slabs, _bullet])
	print("PASS")
	quit(0)


func _chaos(game_seed: int) -> Rec:
	var rec := Rec.new(_rng.randi() if game_seed % 2 == 0 else -_rng.randi(), [], _rng.randf() < 0.1)
	_mash(rec, func() -> int: return TPF)
	return rec


func _subframe(_game_seed: int) -> Rec:
	var rec := Rec.new(_rng.randi())
	_mash(rec, func() -> int: return _rng.randi_range(1, 23))
	return rec


## Full of panels in two colours, with gaps, so nearly every swap and landing makes something big.
func _two_colours(_game_seed: int) -> Rec:
	var ops := [[Replay.OP_CLEAR, 0], [Replay.OP_CLEAR, 1]]
	for p in 2:
		var colours := [_rng.randi_range(1, 5), _rng.randi_range(1, 5)]
		var rows := _rng.randi_range(4, 16)
		for row in rows:
			for x in SimConst.W:
				if _rng.randf() < 0.8:
					ops.append([Replay.OP_PUT, p, x, row, colours[_rng.randi() % 2]])
	var rec := Rec.new(_rng.randi(), ops)
	_mash(rec, func() -> int: return TPF * _rng.randi_range(1, 3))
	return rec


## Queues of slabs of every legal shape, including widths and heights no combo sends.
func _garbage_rain(_game_seed: int) -> Rec:
	var ops := []
	for p in 2:
		for _i in _rng.randi_range(1, 25):
			ops.append([Replay.OP_GARBAGE, p, _rng.randi_range(1, SimConst.W), _rng.randi_range(1, SimConst.BUF)])
	var rec := Rec.new(_rng.randi(), ops)
	_mash(rec, func() -> int: return TPF)
	return rec


func _cpu(_game_seed: int) -> Rec:
	var game_seed := _rng.randi()
	var rec := Rec.new(game_seed)
	var cpus: Array[CpuPlayer] = []
	for p in 2:
		cpus.append(CpuPlayer.opponent(CPUS[_rng.randi() % CPUS.size()], LEVELS[_rng.randi() % LEVELS.size()], game_seed + p))
	while rec.state.winner == -1 and rec.state.tick < HZ * _seconds:
		var i0 := cpus[0].next_input(rec.state.boards[0])
		var i1 := cpus[1].next_input(rec.state.boards[1])
		rec.run(TPF, i0, i1)
		_note(rec)
	return rec


func _mash(rec: Rec, hold: Callable) -> void:
	while rec.state.tick < HZ * _seconds and rec.state.winner == -1:
		var m0 := _mask()
		var m1 := _mask()
		rec.run(hold.call(), m0, m1)
		_note(rec)
	rec.run(HZ) # past the end too: a finished game must stay frozen the same way


func _mask() -> int:
	var m := SimConst.target(_rng.randi() % (SimConst.W - 1), _rng.randi() % SimConst.H)
	if _rng.randf() < 0.1:
		m = 1 << (_rng.randi() % 4) # sometimes a direction, so auto-repeat gets exercised
	if _rng.randf() < 0.4:
		m |= SimConst.SWAP
	if _rng.randf() < 0.03:
		m |= SimConst.RAISE
	return m


func _note(rec: Rec) -> void:
	for b: SimBoard in rec.state.boards:
		_best_combo = maxi(_best_combo, b.fx_combo)
		if b.time_rate < SimConst.TIME_UNIT:
			_bullet += 1
	_slabs = maxi(_slabs, rec.state.boards[0].next_gid - 1 + rec.state.boards[1].next_gid - 1)
