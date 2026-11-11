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
##
## Stalling only stops the bleeding: a gap between the clocks would otherwise last the
## whole match, with the side ahead taking every rollback. So each side measures its
## advantage (its tick minus the tick on the newest packet) and tells the other. A side's
## advantage is how far ahead it runs of the inputs it can see, so equal advantages mean
## equal rollbacks, even over a route that's slower one way. Whichever side has more drops
## a few ticks until they match. Only timing changes, never (tick, input), so the two
## sides can act on different measurements without any risk to determinism.

signal outgoing(packet: Dictionary)
signal desynced(tick: int)

const SNAP_EVERY := SimConst.TICKS_PER_FRAME
const CHECK_EVERY := SimConst.TICK_HZ # exchange a checksum once per second
const MAX_AHEAD := 180 # 250 ms of ticks
const MAX_CHANGES_PER_PACKET := 256
const NEVER := 1 << 40
const SYNC_EVERY := SimConst.TICK_HZ / 2 # re-measure advantage twice a second
const SYNC_DEADBAND := SimConst.TICKS_PER_FRAME / 2 # leave gaps under half a frame alone
const SLEW_SHIFT := 4 # drop at most 1 tick in 16 (6%), too little to notice in play...
const SLEW_SHIFT_COUNTDOWN := 2 # ...and 1 in 4 before the game starts, when nothing's at stake

var state: SimState
var game_seed: int
var check_log := PackedInt64Array() # (tick, hash) pairs of every final checkpoint, for replays
var local_idx: int
var input_delay: int
var remote_frontier := -1
var advantage := NEVER # ticks ahead of the peer's packets, lowest of the last sample period
var stats := {"rollbacks": 0, "resim": 0, "stalls": 0, "slewed": 0}

var _ticks: Array[PackedInt64Array] = [PackedInt64Array([-1]), PackedInt64Array([-1])]
var _masks: Array[PackedInt32Array] = [PackedInt32Array([0]), PackedInt32Array([0])]
var _local_frontier := -1
var _acked := -1 # highest local change tick the peer has confirmed
var _rewind_to := NEVER
var _snaps := {} # tick -> SimState, taken before stepping that tick
var _checks := {} # tick -> checksum, not yet final
var _final_checks := {} # tick -> checksum, final; recent ones ride along in packets
var _remote_checks := {}
var _remote_advantage := NEVER
var _remote_tick := -1 # sender's tick on the newest packet
var _adv_sample := NEVER # lowest advantage this period: jitter only ever adds to it
var _sync_tick := 0 # when the current sample period started
var _slew := 0 # ticks still to drop
var _slew_acc := 0 # ticks run towards the next drop


## backend: "gdscript", or "auto" for the Rust rules wherever they're available.
## rules: what the match plays by, valid; null for the standard rules.
func _init(seed_value: int, idx: int, delay_ticks: int, offline := false, solo := offline, backend := "gdscript", rules: SimRules = null) -> void:
	game_seed = seed_value
	if backend == "auto" and RustState.available():
		state = RustState.make(seed_value, solo, rules)
	else:
		state = SimState.create(seed_value, solo, rules)
	local_idx = idx
	input_delay = delay_ticks
	if offline:
		remote_frontier = NEVER


## Whether set_local_input would record anything this frame (false while stalled).
## Sample stateful input (touch drags) only when this is true, or it gets lost.
func input_open() -> bool:
	return state.tick + input_delay > _local_frontier


## Call once per frame before advance(). The first sample for a given target
## tick wins, so a frontier we've already sent is never contradicted: the peer
## discards anything at or before it, and acting on it here would be a desync.
func set_local_input(mask: int) -> void:
	var t := state.tick + input_delay
	var ts := _ticks[local_idx]
	if t <= _local_frontier:
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
			and pkt.get("s") is int and pkt.get("v") is int
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
	_adv_sample = mini(_adv_sample, state.tick - pkt.s)
	if pkt.s > _remote_tick: # packets can arrive out of order
		_remote_tick = pkt.s
		_remote_advantage = pkt.v
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

	_measure_advantage()
	n -= _take_slew(n)
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
	state.refresh_view()
	return done


## Closes a sample period and sets how many ticks to drop. The gain is 1/2 and the plan is
## replaced rather than added to, so measurements still in flight can't make it overshoot.
func _measure_advantage() -> void:
	if state.tick - _sync_tick < SYNC_EVERY or _adv_sample == NEVER:
		return
	advantage = _adv_sample
	_adv_sample = NEVER
	_sync_tick = state.tick
	_slew = 0
	if _remote_advantage != NEVER:
		var excess := (advantage - _remote_advantage) / 2 # the gap to close is shared
		if excess > SYNC_DEADBAND:
			_slew = excess / 2


## How many of the n ticks due this frame to skip. Tracked per tick, not per
## call, so the rate doesn't depend on the display's frame rate.
func _take_slew(n: int) -> int:
	if _slew <= 0:
		_slew_acc = 0
		return 0
	var shift := SLEW_SHIFT_COUNTDOWN if state.tick < state.rules.countdown else SLEW_SHIFT
	_slew_acc += n
	var drop := mini(mini(_slew, _slew_acc >> shift), n)
	_slew -= drop
	_slew_acc -= drop << shift
	stats.slewed += drop
	return drop


## The agreed inputs up to the last final checkpoint, as parallel (ticks, masks) arrays.
func input_log(p: int, end_tick: int) -> Array:
	var ticks := PackedInt64Array()
	var masks := PackedInt32Array()
	for i in range(1, _ticks[p].size()): # index 0 is the "nothing pressed yet" sentinel
		if _ticks[p][i] < end_tick:
			ticks.append(_ticks[p][i])
			masks.append(_masks[p][i])
	return [ticks, masks]


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
			# A rollback can recompute a checkpoint that's already final, so log each once.
			if check_log.is_empty() or k > check_log[-2]:
				check_log.append(k)
				check_log.append(_checks[k])
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
		"s": state.tick,
		"v": advantage,
	})
