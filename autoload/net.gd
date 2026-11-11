extends Node
## Transport + match handshake, 1v1. Either direct, host/join, for LAN: ENet natively,
## WebSocket where ENet doesn't exist or when config says so. Or through the match server
## (connect_server), which is how the internet plays. Everything above this layer only sees
## Dictionaries, so which one is in use is local to this file.

signal status(text: String)
signal opponent_joined
signal opponent_left
signal match_started
signal packet(pkt: Variant)
signal notice(text: String) # from whoever runs the match server

var hosting := false
var remote_id := 0
var rtt_ms := 0.0
var match_seed := 0
var local_idx := 0
var cpu_name := "" # offline opponent; "" = endless solo
var cpu_level := "normal"
var demo := false # CPU plays your board too (attract mode / footage)

const SERVER_OPPONENT := -1 # remote_id while the opponent is behind the match server
## The public match server, for builds that aren't served by it. Empty: none yet, so native
## builds need [net] server in settings or --server. A web build served from the same host
## finds the server itself (see server_url).
const PUBLIC_SERVER := ""
const ROOM_LETTERS := "ABCDEFGHJKMNPQRSTUVWXYZ23456789" # nothing to misread over a call

var opponent_name := "" # through the match server; "" otherwise
## Why the opponent is gone, when it's more than leaving: the match screen shows it.
var gone_why := ""

var _ping_t := 0.0
var _self_ready := false # rematch handshake (host side)
var _peer_ready := false
var _link: ServerLink # set while using the match server


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(func() -> void: status.emit("Connected — waiting for host…"))
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func use_websocket() -> bool:
	return OS.has_feature("web") or Config.get_value("net", "transport") == "ws"


func host(port: int) -> Error:
	leave()
	var peer: MultiplayerPeer
	var err: Error
	if use_websocket():
		peer = WebSocketMultiplayerPeer.new()
		err = (peer as WebSocketMultiplayerPeer).create_server(port)
	else:
		peer = ENetMultiplayerPeer.new()
		err = (peer as ENetMultiplayerPeer).create_server(port, 1)
	if err != OK:
		status.emit("Can't host on port %d (%s)" % [port, error_string(err)])
		return err
	multiplayer.multiplayer_peer = peer
	hosting = true
	status.emit("Hosting on port %d — waiting for opponent…" % port)
	return OK


func join(address: String, port: int) -> Error:
	leave()
	var peer: MultiplayerPeer
	var err: Error
	if use_websocket():
		peer = WebSocketMultiplayerPeer.new()
		err = (peer as WebSocketMultiplayerPeer).create_client("ws://%s:%d" % [address, port])
	else:
		peer = ENetMultiplayerPeer.new()
		err = (peer as ENetMultiplayerPeer).create_client(address, port)
	if err != OK:
		status.emit("Can't connect (%s)" % error_string(err))
		return err
	multiplayer.multiplayer_peer = peer
	status.emit("Connecting to %s:%d…" % [address, port])
	return OK


## Where the match server is: settings first, then the page's own host on the web, where
## nginx passes /ws to the server, then the built-in one. "" if there's none.
func server_url() -> String:
	var configured: String = str(Config.get_value("net", "server")).strip_edges()
	if configured != "":
		return configured
	if OS.has_feature("web"):
		var loc: Variant = JavaScriptBridge.eval("window.location.protocol + '//' + window.location.host")
		if loc is String and (loc as String).begins_with("http"):
			return (loc as String).replace("https://", "wss://").replace("http://", "ws://") + "/ws"
	return PUBLIC_SERVER


## A link that opens the web game straight into this room, on the same server.
func invite_link(room_code: String) -> String:
	var url := server_url()
	if url == "":
		return ""
	var page := url.replace("wss://", "https://").replace("ws://", "http://").trim_suffix("/ws")
	return "%s/?room=%s" % [page, room_code]


static func new_room_code() -> String:
	var code := ""
	for i in 4:
		code += ROOM_LETTERS[randi() % ROOM_LETTERS.length()]
	return code


## Online through the public match server: quick match, or a room with a friend.
func play_online(room_code := "") -> Error:
	var url := server_url()
	if url == "":
		status.emit("No match server set: add one under Settings")
		return ERR_UNCONFIGURED
	return connect_server(url, room_code)


## Through the match server. An empty room means quick match against whoever's waiting.
func connect_server(url: String, room_code := "") -> Error:
	leave()
	var link := ServerLink.new()
	link.player_name = str(Config.get_value("player", "name"))
	var err := link.open(url)
	if err != OK:
		status.emit("Can't reach the server (%s)" % error_string(err))
		return err
	_link = link
	link.welcomed.connect(func() -> void:
		if room_code == "":
			link.queue()
		else:
			link.room(room_code))
	link.refused.connect(func(why: String) -> void:
		leave()
		status.emit(why))
	link.waiting.connect(func() -> void:
		if room_code == "":
			status.emit("Waiting for an opponent…")
		else:
			var link_text := invite_link(room_code)
			status.emit("Room %s: waiting for your friend.%s" % [room_code,
					"\nInvite link (copied if you made the room): " + link_text if link_text != "" else ""]))
	link.started.connect(_on_server_start)
	link.input.connect(func(pkt: Dictionary) -> void: packet.emit(pkt))
	link.finished.connect(_on_server_result)
	link.pong.connect(_on_rtt_sample)
	link.opponent_left.connect(func() -> void:
		status.emit("Opponent left")
		opponent_left.emit())
	link.notice.connect(func(text: String) -> void:
		status.emit(text)
		notice.emit(text))
	link.closed.connect(_on_server_disconnected)
	status.emit("Connecting to the server…")
	return OK


func leave() -> void:
	if _link:
		_link.close()
		_link = null
	var peer := multiplayer.multiplayer_peer
	if peer and not peer is OfflineMultiplayerPeer:
		peer.close()
	multiplayer.multiplayer_peer = null
	hosting = false
	remote_id = 0
	opponent_name = ""
	gone_why = ""
	rtt_ms = 0.0
	_self_ready = false
	_peer_ready = false


## Offline match: vs a CPU personality at a level, or endless solo when name is "".
func start_practice(name := cpu_name, level := cpu_level) -> void:
	leave()
	cpu_name = name
	cpu_level = level
	match_seed = randi()
	local_idx = 0
	match_started.emit()


## Both players ask; the host starts a fresh match once both have.
func request_rematch() -> void:
	if _link:
		_link.rematch()
	elif remote_id == 0:
		start_practice()
	elif hosting:
		_self_ready = true
		_try_rematch()
	else:
		_rematch_ready.rpc_id(remote_id)


func _try_rematch() -> void:
	if _self_ready and _peer_ready:
		_self_ready = false
		_peer_ready = false
		start_match()


## Host only. Collects a second of pings first so both sides start ~together.
func start_match() -> void:
	status.emit("Opponent joined — syncing…")
	await get_tree().create_timer(1.0).timeout
	if remote_id == 0:
		return
	match_seed = randi()
	local_idx = 0
	gone_why = ""
	_start.rpc_id(remote_id, match_seed)
	await get_tree().create_timer(rtt_ms / 2000.0).timeout
	match_started.emit()


func send(pkt: Dictionary) -> void:
	if _link:
		_link.send_input(pkt)
	elif remote_id != 0:
		_rx.rpc_id(remote_id, pkt)


func _process(delta: float) -> void:
	_ping_t += delta
	if _link:
		_link.poll()
	if remote_id != 0 and _ping_t >= 0.25:
		_ping_t = 0.0
		if _link:
			_link.ping()
		else:
			_ping.rpc_id(remote_id, Time.get_ticks_usec())


func _on_server_start(_match_id: int, game_seed: int, seat: int) -> void:
	remote_id = SERVER_OPPONENT
	opponent_name = _link.opponent_name if _link else ""
	gone_why = ""
	match_seed = game_seed
	local_idx = seat
	match_started.emit()


## A game played to its end needs no announcing: both boards already show it. Any other
## ending comes from the server, and the session would otherwise just stall.
func _on_server_result(winner: int, reason: int, _tick: int) -> void:
	if reason == ServerLink.PLAYED:
		return
	var i_won := winner == local_idx
	match reason:
		ServerLink.STALLED:
			gone_why = "Opponent stopped responding" if i_won else "You stopped responding"
		ServerLink.WRONG_STATE, ServerLink.BAD_INPUT:
			gone_why = "Opponent's game disagreed with the referee" if i_won else "Your game disagreed with the referee"
		ServerLink.ENDED:
			gone_why = "The server ended the match"
		ServerLink.TOO_LONG:
			gone_why = "Out of time: a draw"
	if reason != ServerLink.LEFT:
		status.emit(gone_why)
		opponent_left.emit()


func _on_peer_connected(id: int) -> void:
	if remote_id != 0:
		if hosting:
			multiplayer.multiplayer_peer.disconnect_peer(id)
		return
	remote_id = id
	if hosting:
		multiplayer.multiplayer_peer.refuse_new_connections = true
	opponent_joined.emit()


func _on_peer_disconnected(id: int) -> void:
	if id != remote_id:
		return
	remote_id = 0
	if hosting:
		multiplayer.multiplayer_peer.refuse_new_connections = false
	status.emit("Opponent left")
	opponent_left.emit()


func _on_connection_failed() -> void:
	leave()
	status.emit("Connection failed")


func _on_server_disconnected() -> void:
	var was := "Server" if _link else "Host"
	leave()
	gone_why = "%s disconnected" % was
	status.emit(gone_why)
	opponent_left.emit()


@rpc("authority", "call_remote", "reliable")
func _start(game_seed: int) -> void:
	remote_id = multiplayer.get_remote_sender_id()
	gone_why = ""
	match_seed = game_seed
	local_idx = 1
	match_started.emit()


@rpc("any_peer", "call_remote", "reliable")
func _rematch_ready() -> void:
	if hosting and multiplayer.get_remote_sender_id() == remote_id:
		_peer_ready = true
		_try_rematch()


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _rx(pkt: Variant) -> void:
	if multiplayer.get_remote_sender_id() == remote_id:
		packet.emit(pkt)


@rpc("any_peer", "call_remote", "unreliable")
func _ping(t: int) -> void:
	_pong.rpc_id(multiplayer.get_remote_sender_id(), t)


@rpc("any_peer", "call_remote", "unreliable")
func _pong(t: int) -> void:
	_on_rtt_sample(t)


func _on_rtt_sample(t: int) -> void:
	var sample := (Time.get_ticks_usec() - t) / 1000.0
	rtt_ms = sample if rtt_ms == 0.0 else lerpf(rtt_ms, sample, 0.2)
