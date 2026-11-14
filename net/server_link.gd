class_name ServerLink
extends RefCounted
## The game's end of docs/server-protocol.md: a WebSocket to the match server. The bytes on it
## are made and read by FbgWire, in the Rust extension, which is the same code the server runs.
## Input messages are the Dictionaries RollbackSession already speaks, so the session doesn't
## know a server exists. Call poll() every frame.

signal welcomed(resumed: int) # the match this connection is back in, from its token; 0: none
signal refused(why: String)
signal waiting(here: int, seats: int) # in the queue or a room, `here` of its `seats` taken
signal started(match_id: int, game_seed: int, seat: int)
signal input(pkt: Dictionary)
signal finished(winner: int, reason: int, tick: int) # winner: a team, or -1 for a draw
signal pong(sent_usec: int)
signal opponent_left(seat: int) # after a match: that player left, and this one's in the lobby
signal opponent_away(seat: int, away: bool) # their connection dropped and the match waits, or they're back
signal notice(text: String) # from whoever runs the server
signal closed

const WIRE := "FbgWire"
enum { PLAYED, LEFT, STALLED, WRONG_STATE, BAD_INPUT, TOO_LONG, ENDED }

## Who this player is to the server and the opponent. Set before open().
var player_name := "Player"
## From the latest start, set before `started` is emitted: the other player's name in a 1v1,
## the seats ([{name, team, platform}]), each seat's team, and the match's rules (null:
## standard).
var opponent_name := ""
var seats: Array = []
var teams := PackedInt32Array()
var rules: SimRules = null
## From the latest start: the match, and this seat's token for getting it back after a drop.
var match_id := 0
var resume_token := PackedByteArray()

var _ws := WebSocketPeer.new()
var _wire: Object
var _hello_sent := false
var _resume := PackedByteArray()
var _closed := false


## False in a build without the Rust extension, which can't play online.
static func available() -> bool:
	return ClassDB.class_exists(WIRE)


func _init() -> void:
	if available():
		_wire = ClassDB.instantiate(WIRE)


## resume: a token from an earlier start, to take that seat back.
func open(url: String, resume := PackedByteArray()) -> Error:
	if _wire == null:
		return ERR_UNAVAILABLE
	_resume = resume
	_ws.inbound_buffer_size = 1 << 20
	_ws.outbound_buffer_size = 1 << 20
	return _ws.connect_to_url(url)


func close() -> void:
	_ws.close()
	_closed = true
	_let_go()


## Listeners are often lambdas holding this link, a cycle that would keep it forever.
func _let_go() -> void:
	for sig in get_signal_list():
		for c: Dictionary in get_signal_connection_list(sig.name):
			disconnect(sig.name, c.callable)


## Quick match. Mode 0 is standard 1v1.
func queue(mode := 0) -> void:
	_send(_wire.queue(mode))


## Code: letters and digits, up to 16. The first to ask hosts, and plays on room_rules (null:
## standard) with room_teams, each seat's team (empty: a 1v1); whoever joins plays the host's.
func room(code: String, room_rules: SimRules = null, room_teams := PackedInt32Array()) -> void:
	_send(_wire.room(code, room_rules.encode() if room_rules else PackedByteArray(), PackedByteArray(Array(room_teams))))


func rematch() -> void:
	_send(_wire.rematch())


func ping() -> void:
	_send(_wire.ping(Time.get_ticks_usec()))


## One of RollbackSession's outgoing packets.
func send_input(pkt: Dictionary) -> void:
	_send(_wire.input(pkt))


func poll() -> void:
	if _closed:
		return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _hello_sent:
				_hello_sent = true
				_send(_wire.hello(player_name, platform(), _resume))
			while _ws.get_available_packet_count() > 0 and not _closed:
				decode(_ws.get_packet())
		WebSocketPeer.STATE_CLOSED:
			_closed = true
			closed.emit()
			_let_go()


## What the server's console shows this game running on.
static func platform() -> String:
	if OS.has_feature("web"):
		return "web_android" if OS.has_feature("web_android") else "web_ios" if OS.has_feature("web_ios") else "web"
	return OS.get_name().to_lower().replace(" ", "_").left(16)


func _send(bytes: PackedByteArray) -> void:
	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send(bytes)


## Public so tests can feed it bytes. Damaged messages, and ones from a newer server, are
## ignored.
func decode(bytes: PackedByteArray) -> void:
	if _wire == null:
		return
	var m: Dictionary = _wire.decode(bytes)
	match m.get("type", ""):
		"welcome":
			welcomed.emit(m.resumed)
		"refused":
			refused.emit(m.text)
		"waiting":
			waiting.emit(m.here, m.seats)
		"start":
			var r: SimRules = null
			if not m.rules.is_empty():
				r = SimRules.decode(m.rules)
				if r == null:
					# The server checked them with the same code, so this build is behind it.
					refused.emit("The match's rules are newer than this game. Please update.")
					close()
					return
			rules = r
			match_id = m.match_id
			resume_token = m.resume
			seats = m.seats
			var seat: int = m.seat
			teams = PackedInt32Array()
			for s: Dictionary in seats:
				teams.append(s.team)
			opponent_name = seats[1 - seat].name if seats.size() == 2 and seat < 2 else ""
			started.emit(m.match_id, m.seed, seat)
		"input":
			m.erase("type")
			input.emit(m)
		"result":
			finished.emit(-1 if m.draw else m.winner, m.reason, m.tick)
		"pong":
			pong.emit(m.t)
		"left":
			opponent_left.emit(m.seat)
		"notice":
			notice.emit(m.text)
		"away":
			opponent_away.emit(m.seat, m.away)
