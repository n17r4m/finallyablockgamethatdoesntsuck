class_name EngineProbe
extends Node
## Answers, on whatever machine runs it, whether the Rust rules work there and how fast
## each implementation is. It's the same check on desktop, web and phones, and it stays in
## one scene so exports can run it: a build with the "engine_probe" feature boots here.

signal finished(failed: int)

const DIR := "res://tests/golden"
const RUST := "RustSim"
const ROLLBACK_TICKS := 192

var failed := 0
var _label: Label


func _ready() -> void:
	if DisplayServer.get_name() != "headless":
		_label = Label.new()
		_label.position = Vector2(16, 16)
		_label.add_theme_font_size_override("font_size", 18)
		add_child(_label)
	await _run()
	_say("PASS" if failed == 0 else "FAIL (%d)" % failed)
	finished.emit(failed)


func _say(line: String) -> void:
	print(line)
	if _label:
		_label.text += line + "\n"


func _fail(what: String) -> void:
	failed += 1
	_say("  FAIL " + what)


func _run() -> void:
	_say("%s %s, %s, threads %s" % [OS.get_name(), Engine.get_architecture_name(),
			"debug" if OS.is_debug_build() else "release", "yes" if OS.has_feature("threads") else "no"])
	if not ClassDB.can_instantiate(RUST):
		_fail("the Rust extension didn't load")
		return
	var rust: RefCounted = ClassDB.instantiate(RUST)
	if rust.rules_version() != SimConst.RULES_VERSION:
		_fail("rules version: Rust %d, GDScript %d" % [rust.rules_version(), SimConst.RULES_VERSION])
		return
	var replays := _load_replays()
	if replays.size() < 47:
		_fail("only %d recorded games in this build" % replays.size())
		return
	await _verify_corpus(rust, replays)
	await _compare_tick_by_tick(rust)
	_test_copy(rust)
	_test_refusals(rust, replays)
	await _measure(rust)


func _load_replays() -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	var names := DirAccess.get_files_at(DIR)
	names.sort()
	for name in names:
		if name.ends_with(".fbgr"):
			out.append(FileAccess.get_file_as_bytes("%s/%s" % [DIR, name]))
	return out


## Every recorded game, by both implementations, on this machine.
func _verify_corpus(rust: RefCounted, replays: Array[PackedByteArray]) -> void:
	var rust_usec := 0
	var gd_usec := 0
	for i in replays.size():
		var start := Time.get_ticks_usec()
		var err: String = rust.verify_replay(replays[i])
		rust_usec += Time.get_ticks_usec() - start
		if err != "":
			_fail("Rust, recorded game %d: %s" % [i, err])
		start = Time.get_ticks_usec()
		var gd_err := Replay.decode(replays[i]).verify()
		gd_usec += Time.get_ticks_usec() - start
		if gd_err != "":
			_fail("GDScript, recorded game %d: %s" % [i, gd_err])
		await get_tree().process_frame
	_say("%d recorded games: Rust %.2f s, GDScript %.2f s" % [replays.size(), rust_usec / 1e6, gd_usec / 1e6])


## Through the bridge's own step and hash, on a game no replay holds. Compares whole states,
## so a difference shows the tick it began even if the hash were wrong in the same way twice.
func _compare_tick_by_tick(rust: RefCounted) -> void:
	var rng := RandomNumberGenerator.new()
	var compared := 0
	for game in 8:
		rng.seed = 9000 + game
		var solo := game % 4 == 3
		rust.reset(rng.seed, solo)
		var gd := SimState.create(rng.seed, solo)
		for t in 12000:
			var i0 := _mash(rng)
			var i1 := _mash(rng)
			rust.step(i0, i1)
			gd.step(i0, i1)
			if t % 240 == 0 and rust.canonical_bytes() != gd.canonical_bytes():
				_fail("game %d differs by tick %d" % [game, t])
				return
			compared += 1
			if gd.winner != -1:
				break
		if rust.checksum() != gd.checksum() or rust.winner() != gd.winner or rust.tick() != gd.tick:
			_fail("game %d ended differently" % game)
		await get_tree().process_frame
	_say("Rust and GDScript agree across %d ticks of new games" % compared)


func _mash(rng: RandomNumberGenerator) -> int:
	var roll := rng.randi() % 12
	if roll < 8:
		return 0
	return [SimConst.UP, SimConst.DOWN, SimConst.LEFT, SimConst.RIGHT, SimConst.SWAP, SimConst.SWAP | SimConst.RIGHT, SimConst.RAISE, SimConst.SWAP][roll % 8]


## Rollback depends on a copy sharing nothing with the original.
func _test_copy(rust: RefCounted) -> void:
	rust.reset(77, false)
	for t in 2000:
		rust.step(SimConst.SWAP if t % 60 == 0 else 0, SimConst.LEFT if t % 90 == 0 else 0)
	var saved: RefCounted = rust.copy()
	var before: int = saved.checksum()
	if before != rust.checksum():
		_fail("a copy hashes differently")
	for t in 500:
		rust.step(SimConst.RAISE, SimConst.SWAP)
	if saved.checksum() != before:
		_fail("stepping the original changed its copy")
	if saved.tick() != 2000 or rust.tick() != 2500:
		_fail("copy and original don't keep their own ticks")


## Bad bytes must come back as an answer. A panic here would take the whole game down.
func _test_refusals(rust: RefCounted, replays: Array[PackedByteArray]) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var empty := PackedByteArray()
	if rust.verify_replay(empty) == "":
		_fail("an empty replay was accepted")
	var refused := 0
	for i in 200:
		var bad := replays[i % replays.size()].duplicate()
		bad[rng.randi() % bad.size()] ^= 1 << (rng.randi() % 8)
		if rust.verify_replay(bad) != "":
			refused += 1
	if refused != 200:
		_fail("only %d of 200 damaged replays were refused" % refused)
	else:
		_say("200 of 200 damaged replays refused")


## Times the recorded CPU games, since random mashing leaves boards nearly idle and flatters
## both sides. Ending on the same hash proves each one did the work being timed.
func _measure(rust: RefCounted) -> void:
	var total := 0
	var batch_usec := 0
	var single_usec := 0
	var gd_usec := 0
	var worst_rust := 0
	var worst_gd := 0
	for n in ["cpu_1", "cpu_2", "cpu_3", "cpu_4"]:
		var r := Replay.decode(FileAccess.get_file_as_bytes("%s/%s.fbgr" % [DIR, n]))
		var inputs := _input_table(r)
		var count := inputs.size() / 2
		total += count

		rust.reset(r.game_seed, r.solo)
		var start := Time.get_ticks_usec()
		rust.step_many(inputs)
		batch_usec += Time.get_ticks_usec() - start
		var end_hash: int = rust.checksum()

		rust.reset(r.game_seed, r.solo)
		start = Time.get_ticks_usec()
		for t in count:
			rust.step(inputs[t * 2], inputs[t * 2 + 1])
		single_usec += Time.get_ticks_usec() - start
		if rust.checksum() != end_hash:
			_fail("%s: stepping in a batch and one at a time disagree" % n)

		var gd := r.new_state()
		start = Time.get_ticks_usec()
		for t in count:
			gd.step(inputs[t * 2], inputs[t * 2 + 1])
		gd_usec += Time.get_ticks_usec() - start
		if gd.checksum() != end_hash:
			_fail("%s: Rust and GDScript end differently" % n)

		# The worst the netcode can ask for: restore a copy and replay the deepest rollback.
		var from := maxi(0, count - ROLLBACK_TICKS * 8)
		rust.reset(r.game_seed, r.solo)
		rust.step_many(inputs.slice(0, from * 2))
		gd = r.new_state()
		for t in from:
			gd.step(inputs[t * 2], inputs[t * 2 + 1])
		for t in range(from, count - ROLLBACK_TICKS, ROLLBACK_TICKS):
			var window := inputs.slice(t * 2, (t + ROLLBACK_TICKS) * 2)
			start = Time.get_ticks_usec()
			var rust_copy: RefCounted = rust.copy()
			rust_copy.step_many(window)
			worst_rust = maxi(worst_rust, Time.get_ticks_usec() - start)
			start = Time.get_ticks_usec()
			var gd_copy := gd.copy()
			for w in ROLLBACK_TICKS:
				gd_copy.step(window[w * 2], window[w * 2 + 1])
			worst_gd = maxi(worst_gd, Time.get_ticks_usec() - start)
			rust = rust_copy
			gd = gd_copy
		await get_tree().process_frame

	var batch := float(batch_usec) / total
	var gd_tick := float(gd_usec) / total
	_say("%d ticks of CPU games, per tick: Rust %.2f µs in a batch, %.2f µs one call at a time, GDScript %.2f µs (%.0fx)" % [
			total, batch, float(single_usec) / total, gd_tick, gd_tick / batch])
	_say("Worst %d-tick rollback: Rust %.2f ms, GDScript %.2f ms" % [ROLLBACK_TICKS, worst_rust / 1000.0, worst_gd / 1000.0])
	_say("Share of a core at %d Hz: Rust %.2f%%, GDScript %.2f%%" % [SimConst.TICK_HZ,
			batch * SimConst.TICK_HZ / 10000.0, gd_tick * SimConst.TICK_HZ / 10000.0])


## Each tick's two inputs, flattened. A replay stores only the ticks where an input changes.
func _input_table(r: Replay) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(r.end_tick * 2)
	for p in 2:
		var at := 0
		var mask := 0
		for t in r.end_tick:
			while at < r.ticks[p].size() and r.ticks[p][at] <= t:
				mask = r.masks[p][at]
				at += 1
			out[t * 2 + p] = mask
	return out
