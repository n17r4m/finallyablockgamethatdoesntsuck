extends SceneTree
## Rulesets in play: random valid rulesets play the same game on GDScript and Rust, tick for
## tick; both sides accept and refuse the same bytes; and the switches do what they say.
##   godot --headless --path . -s tests/test_rules_play.gd [-- --games=N]

const CHECK_EVERY := 60

var _failed := 0
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	var games := 24
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--games="):
			games = a.trim_prefix("--games=").to_int()
	_rng.seed = 20261111
	_test_standard_is_the_default()
	_test_switches()
	_test_few_colours()
	if not RustState.available():
		_fail("the Rust extension isn't available: run tools/build_rust_ext.sh linux")
	else:
		_test_same_verdicts()
		_test_same_games(games)
	print("PASS" if _failed == 0 else "FAIL (%d)" % _failed)
	quit(0 if _failed == 0 else 1)


func _fail(what: String) -> void:
	_failed += 1
	print("  FAIL " + what)


## Log-uniform-ish: mostly small, sometimes large, now and then the very ends.
func _span(lo: int, hi: int, typical: int) -> int:
	var roll := _rng.randf()
	if roll < 0.05:
		return lo
	if roll < 0.08:
		return hi
	var top := mini(hi, typical * 4)
	return clampi(int(exp(_rng.randf_range(log(maxf(lo, 1)), log(maxf(top, 2))))), lo, hi)


func _random_line(x_lo: int, x_hi: int, y_hi: int) -> SimRules.Line:
	var n := _rng.randi_range(1, 5)
	var pts := []
	var x := _rng.randi_range(x_lo, x_lo + 50)
	for k in n:
		pts.append([x, _rng.randi_range(0, y_hi)])
		x += _rng.randi_range(1, maxi(1, (x_hi - x_lo) / n))
	return SimRules.Line.new(_rng.randi_range(0, 1), n >= 2 and _rng.randf() < 0.5, pts)


func _random_rules() -> SimRules:
	var r := SimRules.new()
	r.colors = _rng.randi_range(1, SimRules.MAX_COLORS)
	r.manual_raise = _rng.randf() < 0.8
	r.combos_send = _rng.randf() < 0.8
	r.chains_send = _rng.randf() < 0.8
	var standard := SimRules.standard()
	for t: Array in SimRules.TIMINGS:
		var name: String = t[0]
		if name == "countdown":
			r.countdown = _rng.randi_range(0, 720)
		else:
			r.set(name, _span(t[1], t[2], maxi(standard.get(name), 2)))
	r.rise = _random_line(0, 30000, 300)
	r.chain_rows = _random_line(1, 12, SimConst.BUF)
	r.combo_from = _rng.randi_range(3, 7)
	r.combo = []
	for k in _rng.randi_range(1, 10):
		var slabs := []
		for j in _rng.randi_range(0, 4):
			slabs.append(_rng.randi_range(1, SimConst.W))
		r.combo.append(slabs)
	var err := r.validate()
	if err != "":
		_fail("made an invalid ruleset: " + err)
	return r


## Inputs that hold for a while and change, the way people press keys, with some touches.
class Presser:
	var rng: RandomNumberGenerator
	var mask := 0
	var left := 0

	func _init(seed_value: int) -> void:
		rng = RandomNumberGenerator.new()
		rng.seed = seed_value

	func next() -> int:
		if left <= 0:
			left = rng.randi_range(1, 40)
			var roll := rng.randf()
			if roll < 0.1:
				mask = SimConst.target(rng.randi_range(0, SimConst.W - 2), rng.randi_range(0, SimConst.H - 1)) | SimConst.SWAP
			else:
				mask = [0, SimConst.UP, SimConst.DOWN, SimConst.LEFT, SimConst.RIGHT, SimConst.SWAP, SimConst.SWAP, SimConst.RAISE][rng.randi() % 8]
		left -= 1
		return mask


func _test_same_games(games: int) -> void:
	var ticks := 0
	var sent := 0
	var ended := 0
	for g in games:
		var r := _random_rules()
		var game_seed := _rng.randi()
		var gd := SimState.create(game_seed, g % 6 == 5, r)
		var rs := RustState.make(game_seed, g % 6 == 5, r)
		var p0 := Presser.new(game_seed)
		var p1 := Presser.new(game_seed + 1)
		var length := SimConst.TICK_HZ * 20
		for t in length:
			var i0 := p0.next()
			var i1 := p1.next()
			gd.step(i0, i1)
			rs.step(i0, i1)
			if t % CHECK_EVERY == 0 or gd.winner != -1:
				if gd.checksum() != rs.checksum():
					_fail("game %d: GDScript and Rust differ by tick %d on rules %s" % [g, gd.tick, Marshalls.raw_to_base64(r.encode())])
					return
			if gd.winner != -1:
				break
		ticks += gd.tick
		sent += gd.boards[0].sent + gd.boards[1].sent
		ended += 1 if gd.winner != -1 else 0
	print("  ok   %d random rulesets, %d ticks, %d garbage cells sent, %d games ended: GDScript and Rust agree" % [games, ticks, sent, ended])
	if sent == 0:
		_fail("no garbage in any game, so this proves less than it claims")


## Every damaged ruleset is refused by both, or accepted by both.
func _test_same_verdicts() -> void:
	var sim: RefCounted = ClassDB.instantiate(RustState.CLASS)
	var differ := 0
	var accepted := 0
	for k in 3000:
		var b := _random_rules().encode() if k % 3 else SimRules.standard().encode()
		for j in _rng.randi_range(1, 3):
			b[_rng.randi() % b.size()] = _rng.randi() % 256
		var gd_ok := SimRules.decode(b) != null
		var rs_ok: bool = sim.reset_with_rules(1, false, b)
		accepted += 1 if gd_ok else 0
		if gd_ok != rs_ok:
			differ += 1
			if differ == 1:
				_fail("GDScript %s, Rust %s: %s" % [gd_ok, rs_ok, Marshalls.raw_to_base64(b)])
	if differ == 0:
		print("  ok   3000 damaged rulesets: GDScript and Rust agree on all (%d playable)" % accepted)


func _test_standard_is_the_default() -> void:
	var a := SimState.create(99)
	var b := SimState.create(99, false, SimRules.standard())
	var p := Presser.new(5)
	for t in 3000:
		var i := p.next()
		a.step(i, i)
		b.step(i, i)
	if a.checksum() != b.checksum():
		_fail("explicit standard rules play differently from the default")


func _test_switches() -> void:
	# No manual raise: holding RAISE does what holding nothing does.
	var r := SimRules.standard()
	r.manual_raise = false
	var held := SimState.create(3, true, r)
	var idle := SimState.create(3, true, r)
	for t in SimConst.TICK_HZ * 6:
		held.step(SimConst.RAISE, 0)
		idle.step(0, 0)
	# (The last input is state of its own, so compare the stack, not the whole hash.)
	var hb := held.boards[0]
	var ib := idle.boards[0]
	if hb.rise != ib.rise or hb.color != ib.color or hb.age == 0:
		_fail("raise did something with manual raise off (rise %d vs %d)" % [hb.rise, ib.rise])
	# No garbage: a whole match of busy play sends nothing.
	r = SimRules.standard()
	r.combos_send = false
	r.chains_send = false
	var s := SimState.create(8, false, r)
	var c0 := CpuPlayer.opponent("Overmind", "hard", 1)
	var c1 := CpuPlayer.opponent("Architect", "hard", 2)
	for f in 60 * 40:
		var i0 := c0.next_input(s.boards[0])
		var i1 := c1.next_input(s.boards[1])
		for k in SimConst.TICKS_PER_FRAME:
			s.step(i0, i1)
	if s.boards[0].sent + s.boards[1].sent != 0 or s.boards[0].score + s.boards[1].score == 0:
		_fail("garbage off: sent %d, scored %d" % [s.boards[0].sent + s.boards[1].sent, s.boards[0].score + s.boards[1].score])
	# A shorter swap: the timer starts at the rule.
	r = SimRules.standard()
	r.swap = 5
	s = SimState.create(4, true, r)
	for t in r.countdown + 1:
		s.step(0, 0)
	# The bottom visible row is full at the start; swap two different colours there.
	var b := s.boards[0]
	var row := SimConst.ROWS - 1
	var x := 0
	while b.color[row * SimConst.W + x] == b.color[row * SimConst.W + x + 1]:
		x += 1
	s.step(SimConst.target(x, SimConst.H - 1) | SimConst.SWAP, 0)
	var at := row * SimConst.W + x
	# It starts at 5 and counts once in the same tick.
	if b.tm[at] != 4 or b.tm[at + 1] != 4:
		_fail("a swap with swap = 5 didn't start at 5 (%d, %d left)" % [b.tm[at], b.tm[at + 1]])


## Fewer than three colours can't always avoid a triple when a row is made; it still must.
func _test_few_colours() -> void:
	for colours in [1, 2, 3]:
		var r := SimRules.standard()
		r.colors = colours
		var s := SimState.create(17, false, r)
		var p := Presser.new(colours)
		for t in SimConst.TICK_HZ * 10:
			var i := p.next()
			s.step(i | SimConst.RAISE, i)
		for c in s.boards[0].color:
			if c != 0 and c != SimConst.GARBAGE and c > colours:
				_fail("%d colours made a panel of colour %d" % [colours, c])
				return
	print("  ok   1, 2 and 3 colours make rows and play")
