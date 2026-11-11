class_name ServerLink
extends RefCounted
## The game's end of docs/server-protocol.md: a WebSocket to the match server, and the
## messages on it as bytes. Input messages become the Dictionaries RollbackSession already
## speaks, so the session doesn't know a server exists. Call poll() every frame.

signal welcomed
signal refused(why: String)
signal waiting
signal started(match_id: int, game_seed: int, seat: int)
signal input(pkt: Dictionary)
signal finished(winner: int, reason: int, tick: int)
signal pong(sent_usec: int)
signal opponent_left
signal notice(text: String) # from whoever runs the server
signal closed

const PROTOCOL := 2
const MAX_NAME := 24 # bytes of UTF-8
enum { HELLO = 1, QUEUE, ROOM, INPUT, REMATCH, PING }
enum { WELCOME = 64, REFUSED, WAITING, START, RELAY, RESULT, PONG, OPPONENT_LEFT, NOTICE }
enum { PLAYED, LEFT, STALLED, WRONG_STATE, BAD_INPUT, TOO_LONG, ENDED }

## Who this player is to the server and the opponent. Set before open().
var player_name := "Player"
## The other player's name, from the latest start. Set before `started` is emitted.
var opponent_name := ""

var _ws := WebSocketPeer.new()
var _hello_sent := false
var _closed := false


func open(url: String) -> Error:
	_ws.inbound_buffer_size = 1 << 20
	_ws.outbound_buffer_size = 1 << 20
	return _ws.connect_to_url(url)


func close() -> void:
	_ws.close()
	_closed = true


func queue() -> void:
	_send(_writer(QUEUE))


## Code: letters and digits, up to 16.
func room(code: String) -> void:
	var w := _writer(ROOM)
	var bytes := code.to_ascii_buffer()
	w.put_u8(bytes.size())
	w.put_data(bytes)
	_send(w)


func rematch() -> void:
	_send(_writer(REMATCH))


func ping() -> void:
	var w := _writer(PING)
	w.put_64(Time.get_ticks_usec())
	_send(w)


## One of RollbackSession's outgoing packets.
func send_input(pkt: Dictionary) -> void:
	var w := _writer(INPUT)
	w.put_64(pkt.f)
	w.put_64(pkt.a)
	w.put_64(pkt.s)
	w.put_64(pkt.v)
	var t: PackedInt64Array = pkt.t
	var m: PackedInt32Array = pkt.m
	w.put_u16(t.size())
	for i in t.size():
		w.put_64(t[i])
		w.put_32(m[i])
	w.put_u8(pkt.c.size())
	for k: int in pkt.c:
		w.put_64(k)
		w.put_64(pkt.c[k])
	_send(w)


func poll() -> void:
	if _closed:
		return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _hello_sent:
				_hello_sent = true
				var w := _writer(HELLO)
				w.put_u16(PROTOCOL)
				w.put_u16(SimConst.RULES_VERSION)
				w.put_u16(SimConst.TICK_HZ)
				_put_text(w, player_name, MAX_NAME)
				_put_text(w, platform(), 16)
				_send(w)
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


## A length byte and UTF-8, cut to `limit` bytes without splitting a character.
static func _put_text(w: StreamPeerBuffer, text: String, limit: int) -> void:
	var bytes := text.to_utf8_buffer()
	while bytes.size() > limit:
		text = text.left(-1)
		bytes = text.to_utf8_buffer()
	w.put_u8(bytes.size())
	w.put_data(bytes)


## Text after a length byte at `at`, or null if it runs past the end.
static func _text_at(bytes: PackedByteArray, at: int) -> Variant:
	if at >= bytes.size() or at + 1 + bytes[at] > bytes.size():
		return null
	return bytes.slice(at + 1, at + 1 + bytes[at]).get_string_from_utf8()


func _writer(kind: int) -> StreamPeerBuffer:
	var w := StreamPeerBuffer.new()
	w.put_u8(kind)
	return w


func _send(w: StreamPeerBuffer) -> void:
	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send(w.data_array)


## Public so tests can feed it bytes. Short or unknown messages are ignored.
func decode(bytes: PackedByteArray) -> void:
	var r := StreamPeerBuffer.new()
	r.data_array = bytes
	var size := bytes.size()
	if size < 1:
		return
	match r.get_u8():
		WELCOME:
			welcomed.emit()
		REFUSED:
			if size >= 2:
				refused.emit(bytes.slice(2, 2 + bytes[1]).get_string_from_utf8())
		WAITING:
			waiting.emit()
		START:
			var opponent: Variant = _text_at(bytes, 18)
			if size >= 19 and opponent != null and size == 19 + bytes[18]:
				var id := r.get_64()
				var game_seed := r.get_64()
				var seat := r.get_u8()
				opponent_name = opponent
				started.emit(id, game_seed, seat)
		RELAY:
			_decode_input(r, size)
		RESULT:
			if size == 11:
				var winner := r.get_u8()
				var reason := r.get_u8()
				finished.emit(winner, reason, r.get_64())
		PONG:
			if size == 9:
				pong.emit(r.get_64())
		OPPONENT_LEFT:
			opponent_left.emit()
		NOTICE:
			var text: Variant = _text_at(bytes, 1)
			if text != null and size == 2 + bytes[1]:
				notice.emit(text)


func _decode_input(r: StreamPeerBuffer, size: int) -> void:
	if size < 35:
		return
	var pkt := {"f": r.get_64(), "a": r.get_64(), "s": r.get_64(), "v": r.get_64()}
	var n := r.get_u16()
	if r.get_position() + n * 12 + 1 > size:
		return
	var t := PackedInt64Array()
	var m := PackedInt32Array()
	t.resize(n)
	m.resize(n)
	for i in n:
		t[i] = r.get_64()
		m[i] = r.get_32()
	var checks := r.get_u8()
	if r.get_position() + checks * 16 != size:
		return
	var c := {}
	for i in checks:
		var k := r.get_64()
		c[k] = r.get_64()
	pkt.t = t
	pkt.m = m
	pkt.c = c
	input.emit(pkt)
