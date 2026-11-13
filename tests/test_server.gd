extends SceneTree
## Two real sessions playing through a real server over real sockets, in real time. Needs
## fbg-server running; tools/check.sh starts one.
##   godot --headless --path . -s tests/test_server.gd -- --url=ws://127.0.0.1:47110 [--seconds=20] [--bad-link]
## --bad-link delays what each side receives by 30-90 ms, in order, and adds a stall of 200 ms
## twice a second, about what lost packets do to a TCP connection on a poor route.
## --custom plays a room on custom rules from its host: six colours and quicker everything.
## --drop plays player 0 through Net, as the game does, and cuts its connection halfway: it
## must get its seat back and play the match out with no desync.

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
var _custom: SimRules = null
var _inbox: Array = [[], []] # [arrival msec, packet], in order
var _blocked_until := [0, 0]
var _rng := RandomNumberGenerator.new()
var _last_usec := 0
var _began := 0
var _phase := "waiting"
var _settle := 0
var _failed := 0
var _drop := false
var _net: Node
var _dropped := false
var _said: Array[String] = [] # Net's notices, in drop mode
var _away: Array = [] # what link 1 heard about player 0's connection


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--url="):
			_url = a.trim_prefix("--url=")
		elif a.begins_with("--seconds="):
			_seconds = a.trim_prefix("--seconds=").to_int()
		elif a == "--bad-link":
			_bad_link = true
		elif a == "--drop":
			_drop = true
		elif a == "--custom":
			_custom = SimRules.standard()
			_custom.colors = 6
			_custom.swap = 30
			_custom.flash = 300
			_custom.rise = SimRules.Line.new(SimRules.LINEAR, true, [[0, 2], [7200, 4]])
	_test_codec()
	_setup.call_deferred() # the autoloads, Net among them, join the tree after _init


func _setup() -> void:
	var code := "T%d" % (randi() % 1000000)
	if _drop:
		_net = root.get_node("Net")
		_links.append(null) # player 0 is Net's
		for c: Dictionary in _net.match_started.get_connections():
			_net.match_started.disconnect(c.callable) # no match scene: this test is the game
		_net.notice.connect(func(t: String) -> void: _said.append(t))
		_net.match_started.connect(func() -> void:
			_on_started(0, _net.match_seed, _net.local_idx, 0))
		_net.packet.connect(_on_input.bind(0))
	for c in range(1 if _drop else 0, 2):
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
		link.opponent_away.connect(func(away: bool) -> void: _away.append(away))
		_links.append(link)
	if _drop:
		_net.connect_server(_url, code)
	_began = Time.get_ticks_msec()


func _fail(what: String) -> void:
	_failed += 1
	print("  FAIL " + what)


func _finish() -> void:
	for link in _links:
		if link:
			link.close()
	if _net:
		_net.leave()
	print("PASS" if _failed == 0 else "FAIL (%d)" % _failed)
	quit(0 if _failed == 0 else 1)


func _on_welcomed(_resumed: int, c: int, code: String) -> void:
	# Whoever gets there first hosts, and the host's rules are the room's: a joiner's are ignored.
	_links[c].room(code, _custom)


## Everything here is indexed by link. Which seat a link gets is up to the server.
func _on_started(_id: int, game_seed: int, seat: int, c: int) -> void:
	var got: SimRules = _net.match_rules if _drop and c == 0 else _links[c].rules
	if (got == null) != (_custom == null) or (got and got.encode() != _custom.encode()):
		_fail("link %d started on the wrong rules" % c)
	var s := RollbackSession.new(game_seed, seat, 2 * TPF, false, false, "auto" if seat == 0 else "gdscript", got)
	_sessions[c] = s
	_cpus[c] = CpuPlayer.opponent("Overmind", "hard", game_seed + seat)
	s.desynced.connect(func(_t: int) -> void: _desyncs += 1)
	s.outgoing.connect(_net.send if _drop and c == 0 else _links[c].send_input)
	_last_usec = Time.get_ticks_usec()


func _on_input(pkt: Dictionary, c: int) -> void:
	_inbox[c].append([Time.get_ticks_msec() + _rng.randi_range(30, 90) if _bad_link else 0, pkt])


func _process(_delta: float) -> bool:
	if _began == 0:
		return false
	for link in _links:
		if link:
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
	if _drop and not _dropped and Time.get_ticks_msec() - _began > _seconds * 500:
		_dropped = true
		_net._link._ws.close() # as if the phone lost its network
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
	if _drop:
		_links[0] = _net._link
		if _links[0] == null:
			_fail("Net didn't get back on the server: it said %s" % [_said])
			return
		if not "Reconnected" in _said or _away != [true, false]:
			_fail("the drop wasn't seen through: Net said %s, the other player heard %s" % [_said, _away])
		print("  ok   dropped and got back in: %s" % [_said])
	for c in 2:
		if _drop:
			break # Net's player goes by the settings' name
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
	# Replay files can't hold a ruleset yet, so only a standard match's replays can verify.
	for s: RollbackSession in ([a, b] if _custom == null else []):
		var saved := Replay.from_session(s)
		if saved == null or Replay.decode(saved.encode()).verify() != "":
			_fail("a saved replay doesn't verify")
	print("  ok   %d s on the server: ticks %d and %d, rollbacks %d and %d, no desync" % [_seconds, a.state.tick, b.state.tick, a.stats.rollbacks, b.stats.rollbacks])


## The protocol's bytes are fbg-proto's, tested in Rust. This holds the bridge to them:
## what GDScript hands FbgWire comes back the same, and the link turns messages into signals.
func _test_codec() -> void:
	if not ServerLink.available():
		_fail("FbgWire isn't in this build: run tools/build_rust_ext.sh linux")
		return
	var wire: Object = ClassDB.instantiate(ServerLink.WIRE)
	if wire.ping(300) != PackedByteArray([6, 0x08, 0xac, 0x02]):
		_fail("a ping isn't the bytes the Rust tests know: %s" % [wire.ping(300)])
	var link := ServerLink.new()
	var got: Array = []
	link.input.connect(func(p: Dictionary) -> void: got.append(p))
	link.started.connect(func(i: int, g: int, s: int) -> void: got.append([i, g, s]))
	link.finished.connect(func(w: int, r: int, t: int) -> void: got.append([w, r, t]))

	var pkt := {"f": 9, "a": -1, "s": 4, "v": 1 << 40, "t": PackedInt64Array([5, 9]), "m": PackedInt32Array([16, -1]), "c": {720: -7, 360: 1 << 62}}
	var relayed := pkt.duplicate()
	relayed.type = "input"
	relayed.seat = 1
	link.decode(wire.server_bytes(relayed))
	relayed.erase("type")
	if got.size() != 1 or got[0] != relayed:
		_fail("a relayed input decoded wrong: %s" % [got])
	# What the game sends is the same message as what the server relays, bar its number.
	var sent: PackedByteArray = wire.input(pkt)
	var back: PackedByteArray = wire.server_bytes(relayed.merged({"type": "input", "seat": 0}, true))
	if sent.slice(1) != back.slice(1):
		_fail("sent and relayed inputs differ: %s vs %s" % [sent, back])
	# A WebSocket delivers whole frames, so a cut one can't arrive; if it did, it would read
	# as fewer fields or as damage. Either way, nothing breaks.
	var bytes: PackedByteArray = wire.server_bytes(relayed.merged({"type": "input"}))
	for cut in range(1, bytes.size()):
		link.decode(bytes.slice(0, cut))
	got.clear()
	link.decode(PackedByteArray([60, 0x08, 1])) # from a newer server: ignored
	link.decode(PackedByteArray([20, 0x08])) # damaged: ignored
	if not got.is_empty():
		_fail("an unknown or damaged message got through: %s" % [got])

	# A start carries the seats and, for a custom room, the rules.
	var rules := SimRules.standard()
	rules.colors = 6
	var seats := [{"name": "Ann", "team": 0, "platform": "linux"}, {"name": "Zoë", "team": 1, "platform": "web"}]
	link.decode(wire.server_bytes({"type": "start", "match_id": 7, "seed": -3, "seat": 0, "rules": rules.encode(), "seats": seats}))
	if got != [[7, -3, 0]] or link.opponent_name != "Zoë" or link.rules == null or link.rules.colors != 6 or link.seats != seats:
		_fail("a start decoded wrong: %s, %s, %s" % [got, link.opponent_name, link.seats])
	got.clear()
	link.decode(wire.server_bytes({"type": "start", "match_id": 8, "seed": 1, "seat": 1, "seats": seats}))
	if got != [[8, 1, 1]] or link.rules != null or link.opponent_name != "Ann":
		_fail("a standard start decoded wrong: %s" % [got])
	got.clear()
	link.decode(wire.server_bytes({"type": "result", "winner": 0, "draw": true, "reason": ServerLink.ENDED, "tick": 99}))
	if got != [[-1, ServerLink.ENDED, 99]]:
		_fail("a drawn result decoded wrong: %s" % [got])
	var notices: Array = []
	link.notice.connect(func(t: String) -> void: notices.append(t))
	link.decode(wire.server_bytes({"type": "notice", "text": "hi"}))
	if notices != ["hi"]:
		_fail("notices decoded wrong: %s" % [notices])
