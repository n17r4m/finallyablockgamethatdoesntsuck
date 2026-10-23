extends Node
## Transport + match handshake. 1v1, host/join, P2P. ENet natively; WebSocket
## where ENet doesn't exist (web clients) or when config says so. Everything
## above this layer only sees Dictionaries, so swapping in WebRTC later is local.

signal status(text: String)
signal opponent_joined
signal opponent_left
signal match_started
signal packet(pkt: Variant)

var hosting := false
var remote_id := 0
var rtt_ms := 0.0
var match_seed := 0
var local_idx := 0

var _ping_t := 0.0
var _self_ready := false # rematch handshake (host side)
var _peer_ready := false


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


func leave() -> void:
	var peer := multiplayer.multiplayer_peer
	if peer and not peer is OfflineMultiplayerPeer:
		peer.close()
	multiplayer.multiplayer_peer = null
	hosting = false
	remote_id = 0
	rtt_ms = 0.0
	_self_ready = false
	_peer_ready = false


func start_practice() -> void:
	leave()
	match_seed = randi()
	local_idx = 0
	match_started.emit()


## Both players ask; the host starts a fresh match once both have.
func request_rematch() -> void:
	if remote_id == 0:
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
	_start.rpc_id(remote_id, match_seed)
	await get_tree().create_timer(rtt_ms / 2000.0).timeout
	match_started.emit()


func send(pkt: Dictionary) -> void:
	if remote_id != 0:
		_rx.rpc_id(remote_id, pkt)


func _process(delta: float) -> void:
	_ping_t += delta
	if remote_id != 0 and _ping_t >= 0.25:
		_ping_t = 0.0
		_ping.rpc_id(remote_id, Time.get_ticks_usec())


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
	leave()
	status.emit("Host disconnected")
	opponent_left.emit()


@rpc("authority", "call_remote", "reliable")
func _start(game_seed: int) -> void:
	remote_id = multiplayer.get_remote_sender_id()
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
	var sample := (Time.get_ticks_usec() - t) / 1000.0
	rtt_ms = sample if rtt_ms == 0.0 else lerpf(rtt_ms, sample, 0.2)
