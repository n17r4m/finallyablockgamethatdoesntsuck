extends SceneTree
## SimRules: the standard ruleset plays like SimConst, its bytes match rust/sim's (through
## tests/golden/standard.rules), curves fill in exactly, and damaged bytes are refused.
##   godot --headless --path . -s tests/test_rules.gd

const EXPECTED_CHECKS := 284
var _failed := 0
var _ran := 0


func _init() -> void:
	_test_standard_bytes()
	_test_standard_plays_like_the_constants()
	_test_curves()
	_test_limits()
	_test_damage()
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


func _test_standard_bytes() -> void:
	var r := SimRules.standard()
	_check(r.validate() == "", "standard is valid: " + r.validate())
	var bytes := r.encode()
	var want := FileAccess.get_file_as_bytes("res://tests/golden/standard.rules")
	_check(bytes == want, "standard bytes match rust/sim's (%d vs %d bytes)" % [bytes.size(), want.size()])
	var back := SimRules.decode(bytes)
	_check(back != null and back.encode() == bytes, "standard round-trips")
	_check(r.fingerprint() == SimConst.hash64(want), "fingerprint is the hash of the bytes")


func _test_standard_plays_like_the_constants() -> void:
	var r := SimRules.standard()
	var ages := [0, 14399, 14400, 14401, 28800, 5000000]
	for a in range(0, 200000, 37):
		ages.append(a)
	for age: int in ages:
		if r.rise_at(age) != 1 + age / SimConst.SPEEDUP_TICKS:
			_check(false, "rise at %d" % age)
			break
	for n in range(2, 40):
		_check(r.chain_rows_at(n) == mini(n - 1, SimConst.BUF), "chain of %d" % n)
	for n in 200:
		var want: Array = SimConst.COMBO_GARBAGE.get(n, [6, 6, 6]) if n >= 4 else []
		_check(r.combo_slabs(n) == want, "combo of %d" % n)


func _test_curves() -> void:
	var C := SimRules.Line
	var lin: SimRules.Line = C.new(SimRules.LINEAR, false, [[10, 100], [20, 200], [30, 150]])
	_check([0, 10, 15, 20, 25, 29, 30, 99].map(lin.at) == [100, 100, 150, 200, 175, 155, 150, 150], "linear")
	var ext: SimRules.Line = C.new(SimRules.LINEAR, true, [[0, 0], [3, 1]])
	_check([3, 5, 6, 30].map(ext.at) == [1, 1, 2, 10], "linear carries on")
	var down: SimRules.Line = C.new(SimRules.LINEAR, true, [[0, 10], [4, 7]])
	_check([2, 6, 8].map(down.at) == [9, 6, 4], "rounds toward zero, like rust")
	var step: SimRules.Line = C.new(SimRules.STEP, false, [[0, 5], [10, 1]])
	_check([9, 10, 1000].map(step.at) == [5, 1, 1], "step")
	var one: SimRules.Line = C.new(SimRules.LINEAR, false, [[7, 3]])
	_check([-5, 7, 1 << 40].map(one.at) == [3, 3, 3], "one point")


func _bad(change: Callable, word: String) -> void:
	var r := SimRules.standard()
	change.call(r)
	var err := r.validate()
	_check(err.contains(word), "refuses %s (said: %s)" % [word, err])
	_check(SimRules.decode(r.encode()) == null, "decode refuses %s" % word)


func _test_limits() -> void:
	_bad(func(r: SimRules) -> void: r.colors = 0, "colours")
	_bad(func(r: SimRules) -> void: r.colors = 7, "colours")
	_bad(func(r: SimRules) -> void: r.fall = 0, "fall")
	_bad(func(r: SimRules) -> void: r.pop = SimRules.MAX_POP + 1, "pop")
	_bad(func(r: SimRules) -> void: r.repeat_rate = 0, "repeat_rate")
	_bad(func(r: SimRules) -> void: r.time_slow = 0, "time_slow")
	_bad(func(r: SimRules) -> void: r.time_slow = 17, "time_slow")
	_bad(func(r: SimRules) -> void: r.flash = SimRules.FOREVER + 1, "flash")
	_bad(func(r: SimRules) -> void: r.rise.points = [], "rise")
	_bad(func(r: SimRules) -> void: r.rise.points = [[5, 1], [5, 2]], "left to right")
	_bad(func(r: SimRules) -> void: r.rise.points = [[0, 1]], "two points")
	_bad(func(r: SimRules) -> void: r.chain_rows.points = [[1, 0], [2, 13]], "chain_rows")
	_bad(func(r: SimRules) -> void: r.combo_from = 2, "combo")
	_bad(func(r: SimRules) -> void: r.combo = [], "combo")
	_bad(func(r: SimRules) -> void: r.combo = [[7]], "wide")

	# The ends of every range are playable, and survive the trip.
	var r := SimRules.standard()
	r.colors = 1
	r.pop = SimRules.MAX_POP
	r.flash = SimRules.FOREVER
	r.time_slow = 1
	r.repeat_delay = 0
	r.health = 0
	r.combo_from = 3
	var many := []
	many.resize(255)
	many.fill(1)
	r.combo = [[], many]
	r.rise = SimRules.Line.new(SimRules.LINEAR, true, [[0, 0], [SimRules.FOREVER, SimRules.FOREVER]])
	_check(r.validate() == "", "ends of ranges are valid: " + r.validate())
	var back := SimRules.decode(r.encode())
	_check(back != null and back.encode() == r.encode(), "ends of ranges round-trip")
	_check(r.fingerprint() != SimRules.standard().fingerprint(), "a different ruleset, a different fingerprint")
	_check(r.rise_at(2000000) == 2000000 and r.rise_at(1 << 40) == SimRules.FOREVER, "rise is held to forever")


func _test_damage() -> void:
	var good := SimRules.standard().encode()
	var cut_ok := true
	for n in good.size():
		cut_ok = cut_ok and SimRules.decode(good.slice(0, n)) == null
	_check(cut_ok, "every cut-short copy refused")
	var longer := good.duplicate()
	longer.append(0)
	_check(SimRules.decode(longer) == null, "trailing byte refused")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var changed_ok := true
	for i in good.size():
		for k in 16:
			var b := good.duplicate()
			b[i] = rng.randi() % 256
			var r := SimRules.decode(b)
			changed_ok = changed_ok and (r == null or (r.validate() == "" and r.encode() == b))
	_check(changed_ok, "changed bytes are refused or decode to exactly themselves")
