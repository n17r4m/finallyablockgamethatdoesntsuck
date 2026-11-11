class_name ServerLink
extends RefCounted
## The game's end of docs/server-protocol.md: a WebSocket to the match server. The bytes on it
## are made and read by FbgWire, in the Rust extension, which is the same code the server runs.
## Input messages are the Dictionaries RollbackSession already speaks, so the session doesn't
## know a server exists. Call poll() every frame.

signal welcomed
signal refused(why: String)
signal waiting
signal started(match_id: int, game_seed: int, seat: int)
signal input(pkt: Dictionary)
signal finished(winner: int, reason: int, tick: int) # winner -1: a draw
signal pong(sent_usec: int)
signal opponent_left
signal notice(text: String) # from whoever runs the server
signal closed

const WIRE := "FbgWire"
enum { PLAYED, LEFT, STALLED, WRONG_STATE, BAD_INPUT, TOO_LONG, ENDED }

## Who this player is to the server and the opponent. Set before open().
var player_name := "Player"
## From the latest start, set before `started` is emitted: the other player's name, the seats
## ([{name, team, platform}]), and the match's rules (null: standard).
var opponent_name := ""
var seats: Array = []
var rules: SimRules = null

var _ws := WebSocketPeer.new()
var _wire: Object
var _hello_sent := false
var _closed := false


## False in a build without the Rust extension, which can't play online.
static func available() -> bool:
	return ClassDB.class_exists(WIRE)


func _init() -> void:
	if available():
		_wire = ClassDB.instantiate(WIRE)


func open(url: String) -> Error:
	if _wire == null:
		return ERR_UNAVAILABLE
	_ws.inbound_buffer_size = 1 << 20
	_ws.outbound_buffer_size = 1 << 20
	return _ws.connect_to_url(url)


func close() -> void:
	_ws.close()
	_closed = true


## Quick match. Mode 0 is standard 1v1.
func queue(mode := 0) -> void:
	_send(_wire.queue(mode))


## Code: letters and digits, up to 16. The first to ask hosts, and plays on room_rules (null:
## standard); whoever joins plays on the host's.
func room(code: String, room_rules: SimRules = null) -> void:
	_send(_wire.room(code, room_rules.encode() if room_rules else PackedByteArray()))


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
				_send(_wire.hello(player_name, platform()))
			while _ws.get_available_packet_count() > 0 and not _closed:
				decode(_ws.get_packet())
		WebSocketPeer.STATE_CLOSED:
			_closed = true
			closed.emit()


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
			welcomed.emit()
		"refused":
			refused.emit(m.text)
		"waiting":
			waiting.emit()
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
			seats = m.seats
			var seat: int = m.seat
			opponent_name = ""
			for k in seats.size():
				if k != seat:
					opponent_name = seats[k].name
			started.emit(m.match_id, m.seed, seat)
		"input":
			m.erase("type")
			input.emit(m)
		"result":
			finished.emit(-1 if m.draw else m.winner, m.reason, m.tick)
		"pong":
			pong.emit(m.t)
		"left":
			opponent_left.emit()
		"notice":
			notice.emit(m.text)
