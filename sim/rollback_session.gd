class_name RollbackSession
extends RefCounted
## Input-delay + rollback netcode, transport-agnostic (emits/accepts Dictionaries).
##
## Inputs are stored as change events (tick, mask): a player's input at tick t is
## the last change at or before t. That makes prediction implicit — "nothing
## changed" — and a misprediction is simply a remote change arriving for a tick
## we already simulated, so we rewind to the snapshot before it and re-simulate.
##
## Each packet carries the sender's frontier: the tick up to which its input is
## final. We never run more than MAX_AHEAD past the remote frontier (we stall
## instead), which bounds rollback depth and slows down whichever side is ahead.

signal outgoing(packet: Dictionary)
signal desynced(tick: int)

const SNAP_EVERY := SimConst.TICKS_PER_FRAME
const CHECK_EVERY := SimConst.TICK_HZ # exchange a checksum once per second
const MAX_AHEAD := 270 # 250 ms of ticks
const MAX_CHANGES_PER_PACKET := 256
const NEVER := 1 << 40

var state: SimState
var local_idx: int
var input_delay: int
var remote_frontier := -1
var stats := {"rollbacks": 0, "resim": 0, "stalls": 0}

var _ticks: Array[PackedInt64Array] = [PackedInt64Array([-1]), PackedInt64Array([-1])]
var _masks: Array[PackedInt32Array] = [PackedInt32Array([0]), PackedInt32Array([0])]
var _local_frontier := -1
var _acked := -1 # highest local change tick the peer has confirmed
var _rewind_to := NEVER
var _snaps := {} # tick -> SimState, taken before stepping that tick
var _checks := {} # tick -> checksum, not yet final
var _final_checks := {} # tick -> checksum, final; recent ones ride along in packets
var _remote_checks := {}


func _init(game_seed: int, idx: int, delay_ticks: int, offline := false, solo := offline) -> void:
	state = SimState.create(game_seed, solo)
	local_idx = idx
	input_delay = delay_ticks
	if offline:
		remote_frontier = NEVER


## Call once per frame before advance(). The first sample for a given target
## tick wins, so a frontier we've already sent is never contradicted.
func set_local_input(mask: int) -> void:
	var t := state.tick + input_delay
	var ts := _ticks[local_idx]
	if t <= ts[-1]:
		return
	if _masks[local_idx][-1] != mask:
		ts.append(t)
		_masks[local_idx].append(mask)
	_local_frontier = t


## Offline only (CPU opponent): the other board's input, effective this tick.
func set_remote_input(mask: int) -> void:
	var r := 1 - local_idx
	var t := state.tick
	if _ticks[r][-1] == t:
		_masks[r][-1] = mask
	elif _masks[r][-1] != mask:
		_ticks[r].append(t)
		_masks[r].append(mask)


func receive(pkt: Variant) -> void:
	if not (pkt is Dictionary and pkt.get("f") is int and pkt.get("a") is int
			and pkt.get("t") is PackedInt64Array and pkt.get("m") is PackedInt32Array
			and pkt.get("c") is Dictionary):
		return
	var pt: PackedInt64Array = pkt.t
	var pm: PackedInt32Array = pkt.m
	if pt.size() != pm.size() or pt.size() > MAX_CHANGES_PER_PACKET:
		return
	var r := 1 - local_idx
	for i in pt.size():
		var t := pt[i]
		# Anything at or before the known frontier/last change is a resend.
		if t <= _ticks[r][-1] or t <= remote_frontier or t > pkt.f:
			continue
		_ticks[r].append(t)
		_masks[r].append(pm[i])
		if t < state.tick:
			_rewind_to = mini(_rewind_to, t)
	if remote_frontier != NEVER:
		remote_frontier = maxi(remote_frontier, pkt.f)
	_acked = maxi(_acked, pkt.a)
	for k in pkt.c:
		if k is int and pkt.c[k] is int:
			_remote_checks[k] = pkt.c[k]
			_compare(k)


## Simulate up to n ticks. Returns how many actually ran (fewer when stalled).
func advance(n: int) -> int:
	if _rewind_to < state.tick:
		var target := state.tick
		state = _snaps[_rewind_to / SNAP_EVERY * SNAP_EVERY].copy()
		stats.rollbacks += 1
		while state.tick < target:
			_step()
			stats.resim += 1
	_rewind_to = NEVER

	var done := 0
	while done < n:
		if state.tick > remote_frontier + MAX_AHEAD:
			stats.stalls += 1
			break
		_step()
		done += 1

	_prune()
	_finalize_checks()
	_send()
	return done


func input_at(p: int, t: int) -> int:
	return _masks[p][_ticks[p].bsearch(t, false) - 1]


func _step() -> void:
	var t := state.tick
	if t % SNAP_EVERY == 0:
		_snaps[t] = state.copy()
	state.step(input_at(0, t), input_at(1, t))
	if state.tick % CHECK_EVERY == 0:
		_checks[state.tick] = state.checksum()


func _prune() -> void:
	# The next remote change is > remote_frontier, so that's the deepest rewind.
	var keep := (mini(remote_frontier, state.tick) + 1) / SNAP_EVERY * SNAP_EVERY
	for k in _snaps.keys():
		if k < keep:
			_snaps.erase(k)


func _finalize_checks() -> void:
	for k in _checks.keys():
		if k - 1 <= remote_frontier:
			_final_checks[k] = _checks[k]
			_checks.erase(k)
			_compare(k)
	while _final_checks.size() > 4:
		_final_checks.erase(_final_checks.keys().min())


func _compare(k: int) -> void:
	if _final_checks.has(k) and _remote_checks.has(k):
		if _final_checks[k] != _remote_checks[k]:
			desynced.emit(k)
		_remote_checks.erase(k)


func _send() -> void:
	var ts := _ticks[local_idx]
	var from := ts.bsearch(_acked, false)
	var to := mini(ts.size(), from + MAX_CHANGES_PER_PACKET)
	# If truncated, only promise finality up to just before the first unsent change.
	var frontier := _local_frontier if to == ts.size() else ts[to] - 1
	outgoing.emit({
		"f": frontier,
		"t": ts.slice(from, to),
		"m": _masks[local_idx].slice(from, to),
		"a": _ticks[1 - local_idx][-1],
		"c": _final_checks.duplicate(),
	})
