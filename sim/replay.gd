class_name Replay
extends RefCounted
## A whole game as data: seed, starting setup, every input change, and state hashes along
## the way. Anything can check it by re-simulating. The byte layout is specified in
## docs/engine-contract.md; decode() treats its input as hostile, since a server will.

const MAGIC := 0x52474246 # "FBGR", little-endian
const FORMAT := 1
const TRAILER := 8
const MAX_TICKS := SimConst.TICK_HZ * 60 * 60 * 2 # two hours; a limit on verification cost

enum { OP_CLEAR, OP_PUT, OP_GARBAGE }

var rules := SimConst.RULES_VERSION
var tick_hz := SimConst.TICK_HZ
var game_seed := 0
var solo := false
var end_tick := 0
var start_hash := 0
var setup: Array = [] # [kind, board, a, b, c]: see apply_setup
var ticks: Array[PackedInt64Array] = [PackedInt64Array(), PackedInt64Array()]
var masks: Array[PackedInt32Array] = [PackedInt32Array(), PackedInt32Array()]
var check_ticks := PackedInt64Array()
var check_hashes := PackedInt64Array()
var error := "" # set by decode(); a replay with an error must not be used
var final_state: SimState # set by verify()

var _b := PackedByteArray()
var _p := 0


## A replay of what a session agreed on, or null if it hasn't reached a checkpoint yet.
## Doesn't simulate anything, so it's cheap to call when a match ends.
static func from_session(s: RollbackSession) -> Replay:
	if s.check_log.is_empty():
		return null
	var r := Replay.new()
	r.game_seed = s.game_seed
	r.solo = s.state.solo
	r.end_tick = s.check_log[-2]
	r.start_hash = SimState.create(s.game_seed, s.state.solo).checksum()
	for i in range(0, s.check_log.size(), 2):
		r.check_ticks.append(s.check_log[i])
		r.check_hashes.append(s.check_log[i + 1])
	for p in 2:
		var log := s.input_log(p, r.end_tick)
		r.ticks[p] = log[0]
		r.masks[p] = log[1]
	return r


## A replay made from scratch. Simulates it to fill in the hashes: a checkpoint
## every second and one at the end.
static func build(seed_value: int, solo_mode: bool, ops: Array, in_ticks: Array, in_masks: Array, end: int) -> Replay:
	var r := Replay.new()
	r.game_seed = seed_value
	r.solo = solo_mode
	r.setup = ops
	r.end_tick = end
	for p in 2:
		r.ticks[p] = in_ticks[p]
		r.masks[p] = in_masks[p]
	r.start_hash = r.new_state().checksum()
	r._simulate(false, Callable())
	return r


## The state at tick 0, before any input.
func new_state() -> SimState:
	var s := SimState.create(game_seed, solo)
	apply_setup(s, setup)
	return s


static func apply_setup(s: SimState, ops: Array) -> void:
	for op: Array in ops:
		var b := s.boards[op[1]]
		match op[0]:
			OP_CLEAR:
				b.clear_all()
			OP_PUT:
				b.put(op[2], op[3], op[4])
			OP_GARBAGE:
				b.receive_garbage(PackedInt32Array([SimConst.slab(op[2], op[3])]))


## Re-simulates and checks every hash. Returns "" if the game is genuine, else what's wrong.
## on_tick, if given, is called with the state after every tick.
func verify(on_tick := Callable()) -> String:
	if rules != SimConst.RULES_VERSION:
		return "rules version %d, this build is %d" % [rules, SimConst.RULES_VERSION]
	if tick_hz != SimConst.TICK_HZ:
		return "tick rate %d, this build is %d" % [tick_hz, SimConst.TICK_HZ]
	return _simulate(true, on_tick)


func _simulate(check: bool, on_tick: Callable) -> String:
	var s := new_state()
	final_state = s
	if check and s.checksum() != start_hash:
		return "start state differs"
	var call_back := on_tick.is_valid()
	var t0 := ticks[0]
	var t1 := ticks[1]
	var i0 := 0
	var i1 := 0
	var m0 := 0
	var m1 := 0
	var next_check := 0
	for t in end_tick:
		if i0 < t0.size() and t0[i0] == t:
			m0 = masks[0][i0]
			i0 += 1
		if i1 < t1.size() and t1[i1] == t:
			m1 = masks[1][i1]
			i1 += 1
		s.step(m0, m1)
		if call_back:
			on_tick.call(s)
		if check:
			if next_check < check_ticks.size() and check_ticks[next_check] == s.tick:
				if s.checksum() != check_hashes[next_check]:
					return "state differs at tick %d" % s.tick
				next_check += 1
		elif s.tick % SimConst.TICK_HZ == 0 or s.tick == end_tick:
			check_ticks.append(s.tick)
			check_hashes.append(s.checksum())
	if check and next_check != check_ticks.size():
		return "checkpoints past the end"
	return ""


# --- writing ------------------------------------------------------------------

func encode() -> PackedByteArray:
	var out := StreamPeerBuffer.new()
	out.put_u32(MAGIC)
	out.put_u8(FORMAT)
	out.put_u16(rules)
	out.put_u16(tick_hz)
	out.put_u8(1 if solo else 0)
	out.put_64(game_seed)
	_put_var(out, end_tick)
	out.put_64(start_hash)
	_put_var(out, setup.size())
	for op: Array in setup:
		out.put_u8(op[0])
		out.put_u8(op[1])
		if op[0] != OP_CLEAR:
			out.put_u8(op[2])
			out.put_u8(op[3])
		if op[0] == OP_PUT:
			out.put_u8(op[4])
	for p in 2:
		_put_var(out, ticks[p].size())
		var prev := -1
		for i in ticks[p].size():
			_put_var(out, ticks[p][i] - prev)
			_put_var(out, masks[p][i])
			prev = ticks[p][i]
	_put_var(out, check_ticks.size())
	var prev_check := 0
	for i in check_ticks.size():
		_put_var(out, check_ticks[i] - prev_check)
		out.put_64(check_hashes[i])
		prev_check = check_ticks[i]
	return seal(out.data_array)


## Appends the integrity trailer. It catches damage, not forgery: a forged replay has to
## survive verify(), and the referee is what makes that matter.
static func seal(body: PackedByteArray) -> PackedByteArray:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(body)
	return body + h.finish().slice(0, TRAILER)


func _put_var(out: StreamPeerBuffer, v: int) -> void:
	while v >= 0x80:
		out.put_u8((v & 0x7F) | 0x80)
		v >>= 7
	out.put_u8(v)


# --- reading ------------------------------------------------------------------

## Never fails outright: check .error on the result. Nothing in the input can make
## this read out of bounds, allocate more than the input's size, or run unbounded.
static func decode(bytes: PackedByteArray) -> Replay:
	var r := Replay.new()
	r._read(bytes)
	r._b = PackedByteArray()
	return r


func _read(bytes: PackedByteArray) -> void:
	if bytes.size() < 4 + 1 + 2 + 2 + 1 + 8 + TRAILER:
		error = "too short"
		return
	var body := bytes.slice(0, bytes.size() - TRAILER)
	if seal(body) != bytes:
		error = "damaged: integrity trailer doesn't match"
		return
	_b = body
	_p = 0
	if bytes.decode_u32(0) != MAGIC:
		error = "not a replay"
		return
	_p = 4
	var format := _b.decode_u8(_p)
	_p += 1
	if format != FORMAT:
		error = "replay format %d, this build reads %d" % [format, FORMAT]
		return
	rules = _b.decode_u16(_p)
	tick_hz = _b.decode_u16(_p + 2)
	_p += 4
	var flags := _b.decode_u8(_p)
	_p += 1
	if flags > 1:
		error = "unknown flags"
		return
	solo = flags == 1
	game_seed = _b.decode_s64(_p)
	_p += 8
	end_tick = _var()
	if error != "":
		return
	if end_tick > MAX_TICKS:
		error = "too long"
		return
	if not _have(8):
		return
	start_hash = _b.decode_s64(_p)
	_p += 8
	_read_setup()
	for p in 2:
		if error == "":
			_read_inputs(p)
	if error == "":
		_read_checks()
	if error == "" and _p != _b.size():
		error = "trailing bytes"


func _read_setup() -> void:
	var n := _count()
	for _i in n:
		if not _have(2):
			return
		var kind := _b.decode_u8(_p)
		var board := _b.decode_u8(_p + 1)
		_p += 2
		if board > 1:
			error = "bad board in setup"
			return
		match kind:
			OP_CLEAR:
				setup.append([kind, board])
			OP_PUT:
				if not _have(3):
					return
				var x := _b.decode_u8(_p)
				var row := _b.decode_u8(_p + 1)
				var c := _b.decode_u8(_p + 2)
				_p += 3
				if x >= SimConst.W or row >= SimConst.ROWS or c > SimConst.COLORS:
					error = "bad cell in setup"
					return
				setup.append([kind, board, x, row, c])
			OP_GARBAGE:
				if not _have(2):
					return
				var w := _b.decode_u8(_p)
				var h := _b.decode_u8(_p + 1)
				_p += 2
				if w < 1 or w > SimConst.W or h < 1 or h > SimConst.BUF:
					error = "bad slab in setup"
					return
				setup.append([kind, board, w, h])
			_:
				error = "unknown setup op"
				return


func _read_inputs(p: int) -> void:
	var n := _count()
	var prev := -1
	for _i in n:
		var delta := _var()
		var mask := _var()
		if error != "":
			return
		if delta < 1:
			error = "input ticks must ascend"
			return
		prev += delta
		if prev >= end_tick:
			error = "input past the end"
			return
		if mask & ~SimConst.INPUT_BITS:
			error = "unknown input bits"
			return
		ticks[p].append(prev)
		masks[p].append(mask)


func _read_checks() -> void:
	var n := _count()
	var prev := 0
	for _i in n:
		var delta := _var()
		if error != "" or not _have(8):
			return
		if delta < 1:
			error = "checkpoints must ascend"
			return
		prev += delta
		check_ticks.append(prev)
		check_hashes.append(_b.decode_s64(_p))
		_p += 8
	if check_ticks.is_empty():
		error = "no checkpoints"
	elif prev != end_tick:
		error = "last checkpoint isn't the end"


## An element count. Every element takes at least a byte, so more than what's left is a lie.
func _count() -> int:
	var n := _var()
	if error == "" and n > _b.size() - _p:
		error = "count larger than the file"
		return 0
	return n


## An unsigned LEB128 varint of at most 62 bits.
func _var() -> int:
	var v := 0
	var shift := 0
	while true:
		if not _have(1):
			return 0
		var byte := _b.decode_u8(_p)
		_p += 1
		if shift > 55 or (byte == 0 and shift > 0):
			error = "bad varint"
			return 0
		v |= (byte & 0x7F) << shift
		if byte < 0x80:
			return v
		shift += 7
	return 0


func _have(n: int) -> bool:
	if _p + n > _b.size():
		if error == "":
			error = "truncated"
		return false
	return true
