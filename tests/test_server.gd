extends SceneTree
## Two real sessions playing through a real server over real sockets, in real time. Needs
## fbg-server running; tools/check.sh starts one.
##   godot --headless --path . -s tests/test_server.gd -- --url=ws://127.0.0.1:47110 [--seconds=20] [--bad-link]
## --bad-link delays what each side receives by 30-90 ms, in order, and adds a stall of 200 ms
## twice a second, about what lost packets do to a TCP connection on a poor route.

const TPF := SimConst.TICKS_PER_FRAME

var _url := "ws://127.0.0.1:47110"
var _seconds := 20
var _links: Array[ServerLink] = []
var _sessions: Array[RollbackSession] = [null, null]
var _cpus: Array[CpuPlayer] = [null, null]
var _desyncs := 0
var _results: Array = []
var _acc := 0 # tick-units * 1e6, as in scenes/match.gd
var _bad_link := false
var _inbox: Array = [[], []] # [arrival msec, packet], in order
var _blocked_until := [0, 0]
var _rng := RandomNumberGenerator.new()
var _last_usec := 0
var _began := 0
var _phase := "waiting"
var _settle := 0
var _failed := 0


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--url="):
			_url = a.trim_prefix("--url=")
		elif a.begins_with("--seconds="):
			_seconds = a.trim_prefix("--seconds=").to_int()
		elif a == "--bad-link":
			_bad_link = true
	_test_codec()
	var code := "T%d" % (randi() % 1000000)
	for c in 2:
		var link := ServerLink.new()
		link.player_name = "Tester %d" % c
		if link.open(_url) != OK:
			_fail("can't open a socket")
			_finish()
			return
		link.welcomed.connect(_on_welcomed.bind(c, code))
		link.refused.connect(func(why: String) -> void: _fail("refused: " + why))
		link.started.connect(_on_started.bind(c))
		link.finished.connect(func(w: int, r: int, t: int) -> void: _results.append([w, r, t]))
		link.input.connect(_on_input.bind(c))
		_links.append(link)
	_began = Time.get_ticks_msec()


func _fail(what: String) -> void:
	_failed += 1
	print("  FAIL " + what)


func _finish() -> void:
	for link in _links:
		link.close()
	print("PASS" if _failed == 0 else "FAIL (%d)" % _failed)
	quit(0 if _failed == 0 else 1)


func _on_welcomed(c: int, code: String) -> void:
	_links[c].room(code)


## Everything here is indexed by link. Which seat a link gets is up to the server.
func _on_started(_id: int, game_seed: int, seat: int, c: int) -> void:
	var s := RollbackSession.new(game_seed, seat, 2 * TPF, false, false, "auto" if seat == 0 else "gdscript")
	_sessions[c] = s
	_cpus[c] = CpuPlayer.opponent("Overmind", "hard", game_seed + seat)
	s.desynced.connect(func(_t: int) -> void: _desyncs += 1)
	s.outgoing.connect(_links[c].send_input)
	_last_usec = Time.get_ticks_usec()


func _on_input(pkt: Dictionary, c: int) -> void:
	_inbox[c].append([Time.get_ticks_msec() + _rng.randi_range(30, 90) if _bad_link else 0, pkt])


func _process(_delta: float) -> bool:
	for link in _links:
		link.poll()
	if _sessions[0] == null or _sessions[1] == null:
		if Time.get_ticks_msec() - _began > 5000:
			_fail("no match within 5 s: is fbg-server running at %s?" % _url)
			_finish()
		return false
	var now := Time.get_ticks_usec()
	_acc += (now - _last_usec) * SimConst.TICK_HZ
	_last_usec = now
	var due := mini(_acc / 1000000, SimConst.TICK_HZ / 10)
	_acc = mini(_acc - due * 1000000, 1000000)
	for c in 2:
		_deliver(c)
		var s := _sessions[c]
		if s.input_open():
			s.set_local_input(_cpus[c].next_input(s.state.boards[s.local_idx]))
		s.advance(due)
	if Time.get_ticks_msec() - _began > _seconds * 1000:
		_check()
		_finish()
	return false


func _deliver(c: int) -> void:
	var msec := Time.get_ticks_msec()
	if _bad_link and _rng.randf() < 0.002:
		_blocked_until[c] = msec + 200
	if msec < _blocked_until[c]:
		return
	while not _inbox[c].is_empty() and _inbox[c][0][0] <= msec:
		_sessions[c].receive(_inbox[c].pop_front()[1])


func _check() -> void:
	var a := _sessions[0]
	var b := _sessions[1]
	for c in 2:
		if _links[c].opponent_name != "Tester %d" % (1 - c):
			_fail("link %d was told its opponent is %s" % [c, _links[c].opponent_name])
	if (a.state is RustState) == (b.state is RustState):
		_fail("this test wants one Rust player and one GDScript player")
	if _desyncs != 0:
		_fail("%d desyncs" % _desyncs)
	if a.check_log.size() < 10 or b.check_log.size() < 10:
		_fail("too few agreed checkpoints: %d and %d" % [a.check_log.size(), b.check_log.size()])
	for r: Array in _results:
		if r[1] != ServerLink.PLAYED:
			_fail("the server ended the match: winner %d, reason %d, tick %d" % r)
	for s: RollbackSession in [a, b]:
		var saved := Replay.from_session(s)
		if saved == null or Replay.decode(saved.encode()).verify() != "":
			_fail("a saved replay doesn't verify")
	print("  ok   %d s on the server: ticks %d and %d, rollbacks %d and %d, no desync" % [_seconds, a.state.tick, b.state.tick, a.stats.rollbacks, b.stats.rollbacks])


## Byte layouts from docs/server-protocol.md, written out by hand: the Rust tests hold the
## other side of the same bytes.
func _test_codec() -> void:
	var link := ServerLink.new()
	var got: Array = []
	link.input.connect(func(p: Dictionary) -> void: got.append(p))
	link.started.connect(func(i: int, g: int, s: int) -> void: got.append([i, g, s]))
	link.finished.connect(func(w: int, r: int, t: int) -> void: got.append([w, r, t]))
	var w := StreamPeerBuffer.new()
	w.put_u8(ServerLink.RELAY)
	for v: int in [9, -1, 4, 1 << 40]:
		w.put_64(v)
	w.put_u16(1)
	w.put_64(5)
	w.put_32(16)
	w.put_u8(1)
	w.put_64(720)
	w.put_64(-7)
	link.decode(w.data_array)
	if got.size() != 1 or got[0].f != 9 or got[0].a != -1 or got[0].s != 4 or got[0].v != 1 << 40 \
			or got[0].t != PackedInt64Array([5]) or got[0].m != PackedInt32Array([16]) or got[0].c != {720: -7}:
		_fail("a relayed input decoded wrong: %s" % [got])
	got.clear()
	for cut in w.data_array.size():
		link.decode(w.data_array.slice(0, cut))
	if not got.is_empty():
		_fail("a cut-off input was accepted")
	var extra := w.data_array.duplicate()
	extra.append(0)
	link.decode(extra)
	if not got.is_empty():
		_fail("an input with trailing bytes was accepted")
	var huge := w.data_array.duplicate()
	huge[33] = 0xFF
	huge[34] = 0xFF
	link.decode(huge)
	if not got.is_empty():
		_fail("an input claiming too many changes was accepted")

	# Start carries the opponent's name, and a notice is text: both a length byte then UTF-8.
	var start := StreamPeerBuffer.new()
	start.put_u8(ServerLink.START)
	start.put_64(7)
	start.put_64(-3)
	start.put_u8(1)
	var name := "Zoë".to_utf8_buffer()
	start.put_u8(name.size())
	start.put_data(name)
	link.decode(start.data_array)
	if got != [[7, -3, 1]] or link.opponent_name != "Zoë":
		_fail("a start decoded wrong: %s, %s" % [got, link.opponent_name])
	got.clear()
	link.decode(start.data_array.slice(0, start.data_array.size() - 1))
	if not got.is_empty():
		_fail("a cut-off start was accepted")
	var notices: Array = []
	link.notice.connect(func(t: String) -> void: notices.append(t))
	var note := PackedByteArray([ServerLink.NOTICE, 2]) + "hi".to_utf8_buffer()
	link.decode(note)
	link.decode(note.slice(0, 3))
	if notices != ["hi"]:
		_fail("notices decoded wrong: %s" % [notices])
