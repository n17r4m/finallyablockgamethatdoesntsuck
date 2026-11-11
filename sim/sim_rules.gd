class_name SimRules
extends RefCounted
## A ruleset: every number a match is played with that isn't the shape of the well or the tick
## rate. SimRules.standard() is the game as it has always played. rust/sim/src/rules.rs is the
## other copy; the byte layout in docs/engine-contract.md is what both must agree on, and
## tests/golden/standard.rules holds them to it.
##
## Zero, one or infinity: each limit exists because something breaks without it, and says what.
## "Forever" is the longest game a replay may hold; a longer time can't be told from forever.

const LAYOUT := 1
const MAGIC := "FBRU"
const FOREVER := SimConst.TICK_HZ * 60 * 60 * 2 # Replay's two-hour limit
## Pop and reveal times add up across a whole clear or slab (up to every cell), and the sum
## shares a 32-bit cell with another timer, 16 bits each.
const MAX_POP := 32767 / (SimConst.W * SimConst.ROWS)
const MAX_COLORS := SimConst.GARBAGE - 1 # cell value 7 is garbage
const MIN_CLEAR := 3
const MAX_ENTRIES := 255 # a byte counts them
const MAX_POINTS := 255
const LINEAR := 0
const STEP := 1
const CELL := 1 # a cell's timer counts down to exactly zero, so it must start above it

## Scalar timings in layout order: [name, lowest, highest].
const TIMINGS := [
	["swap", CELL, FOREVER], ["hover", CELL, FOREVER], ["fall", CELL, FOREVER],
	["land", CELL, FOREVER], ["flash", CELL, FOREVER], ["pop", CELL, MAX_POP],
	["reveal", CELL, MAX_POP], ["shell_pop", CELL, MAX_POP], ["garbage_hang", CELL, FOREVER],
	["repeat_delay", 0, FOREVER],
	["repeat_rate", 1, FOREVER], # repeats every this many ticks
	["time_slow", 1, SimConst.TIME_UNIT], # at 0 the crack never ends
	["time_ramp", 0, FOREVER], ["row_units", 1, FOREVER], ["raise_speed", 0, FOREVER],
	["stop", 0, FOREVER], ["countdown", 0, FOREVER], ["health", 0, FOREVER],
	["garbage_delay", 0, FOREVER], ["garbage_gap", 0, FOREVER],
]

var colors := SimConst.COLORS
var manual_raise := true
var combos_send := true
var chains_send := true

var swap := SimConst.SWAP_TICKS
var hover := SimConst.HOVER_TICKS
var fall := SimConst.FALL_TICKS
var land := SimConst.LAND_TICKS
var flash := SimConst.FLASH_TICKS
var pop := SimConst.POP_TICKS
var reveal := SimConst.REVEAL_TICKS
var shell_pop := SimConst.SHELL_POP_TICKS
var garbage_hang := SimConst.GARBAGE_HANG_TICKS
var repeat_delay := SimConst.REPEAT_DELAY
var repeat_rate := SimConst.REPEAT_RATE
var time_slow := SimConst.TIME_SLOW # the world's speed while garbage cracks, in sixteenths
var time_ramp := SimConst.TIME_RAMP
var row_units := SimConst.ROW_UNITS # rise needed for one row
var raise_speed := SimConst.RAISE_SPEED
var stop := SimConst.STOP_TICKS
var countdown := SimConst.COUNTDOWN_TICKS
var health := SimConst.HEALTH_TICKS
var garbage_delay := SimConst.GARBAGE_DELAY
var garbage_gap := SimConst.GARBAGE_GAP

## Rise per tick against the board's age: 1 + age / SPEEDUP_TICKS.
var rise := Line.new(STEP, true, [[0, 1], [SimConst.SPEEDUP_TICKS, 2]])
## Rows of full-width garbage a chain sends when it ends, against its length: length - 1.
var chain_rows := Line.new(LINEAR, true, [[1, 0], [2, 1]])
## Slab widths sent by a clear of combo_from panels, then one more, and so on. The last entry is
## for every bigger clear.
var combo_from := 4
var combo: Array = [[3], [4], [5], [6], [3, 4], [4, 4], [5, 5], [5, 6], [6, 6], [6, 6, 6]]


## A value that depends on another: points [x, y] with x strictly increasing. Before the first
## point it's the first y. After the last it holds, or, with extend, carries on the way the last
## two points go. Integers only, rounding toward zero, the same as rust/sim.
class Line:
	## (Godot already has a Curve class; this is the same thing as rust's Curve.)
	var fill := LINEAR
	var extend := false
	var points: Array = []

	func _init(f := LINEAR, e := false, p: Array = []) -> void:
		fill = f
		extend = e
		points = p

	func at(x: int) -> int:
		var p := points
		if x <= p[0][0] or p.size() == 1:
			return p[0][1]
		for k in range(1, p.size()):
			if x < p[k][0]:
				var a: Array = p[k - 1]
				if fill == STEP:
					return a[1]
				return a[1] + (p[k][1] - a[1]) * (x - a[0]) / (p[k][0] - a[0])
		var a: Array = p[-2]
		var b: Array = p[-1]
		if not extend:
			return b[1]
		var dx: int = b[0] - a[0]
		var dy: int = b[1] - a[1]
		if fill == STEP:
			return b[1] + (x - b[0]) / dx * dy
		return b[1] + (x - b[0]) * dy / dx

	func check(what: String, x_min: int, y_min: int, y_max: int) -> String:
		if points.is_empty() or points.size() > MAX_POINTS:
			return "%s: needs 1 to %d points" % [what, MAX_POINTS]
		if extend and points.size() < 2:
			return "%s: carrying on needs two points to follow" % what
		for k in points.size():
			var x: int = points[k][0]
			var y: int = points[k][1]
			if x < x_min or x > FOREVER:
				return "%s: point %d is at %d, outside %d to %d" % [what, k, x, x_min, FOREVER]
			if y < y_min or y > y_max:
				return "%s: point %d is %d, outside %d to %d" % [what, k, y, y_min, y_max]
			if k > 0 and x <= points[k - 1][0]:
				return "%s: points must go left to right" % what
		return ""

	func write(out: StreamPeerBuffer) -> void:
		out.put_u8(fill)
		out.put_u8(1 if extend else 0)
		out.put_u8(points.size())
		for pt: Array in points:
			out.put_32(pt[0])
			out.put_32(pt[1])

	func duplicate() -> Line:
		return Line.new(fill, extend, points.duplicate(true))


static func standard() -> SimRules:
	return SimRules.new()


static var _shared: SimRules


## One standard ruleset for every match that doesn't ask for another. Don't change it.
static func shared_standard() -> SimRules:
	if _shared == null:
		_shared = SimRules.new()
	return _shared


## "" if the sim can play these rules: every game ends, and nothing overflows. Else what's wrong.
func validate() -> String:
	if colors < 1 or colors > MAX_COLORS:
		return "colours: 1 to %d" % MAX_COLORS
	for t: Array in TIMINGS:
		var v: int = get(t[0])
		if v < t[1] or v > t[2]:
			return "%s: %d is outside %d to %d" % [t[0], v, t[1], t[2]]
	var err := rise.check("rise", 0, 0, FOREVER)
	if err == "":
		err = chain_rows.check("chain_rows", 1, 0, SimConst.BUF) # a chain is 2 or longer
	if err != "":
		return err
	if combo_from < MIN_CLEAR or combo_from > 255:
		return "combo table: starts at %d or more, the smallest clear" % MIN_CLEAR
	if combo.is_empty() or combo.size() > MAX_ENTRIES:
		return "combo table: 1 to %d entries" % MAX_ENTRIES
	for k in combo.size():
		var slabs: Array = combo[k]
		if slabs.size() > MAX_ENTRIES:
			return "combo table: entry %d has more than %d slabs" % [k, MAX_ENTRIES]
		for w: int in slabs:
			if w < 1 or w > SimConst.W:
				return "combo table: entry %d: slabs are 1 to %d wide" % [k, SimConst.W]
	return ""


## Rise this tick, at this age. Held to forever per tick, so a sum over a game stays in range.
func rise_at(age: int) -> int:
	return clampi(rise.at(age), 0, FOREVER)


## Rows a chain of length n sends: no more than the hidden rows above the well can hold.
func chain_rows_at(n: int) -> int:
	return clampi(chain_rows.at(n), 0, SimConst.BUF)


## Slab widths a clear of n panels sends.
func combo_slabs(n: int) -> Array:
	if n < combo_from:
		return []
	return combo[mini(n - combo_from, combo.size() - 1)]


func encode() -> PackedByteArray:
	var out := StreamPeerBuffer.new()
	out.put_data(MAGIC.to_ascii_buffer())
	out.put_u8(LAYOUT)
	out.put_u8(colors)
	out.put_u8(int(manual_raise) | int(combos_send) << 1 | int(chains_send) << 2)
	for t: Array in TIMINGS:
		out.put_32(get(t[0]))
	rise.write(out)
	chain_rows.write(out)
	out.put_u8(combo_from)
	out.put_u8(combo.size())
	for slabs: Array in combo:
		out.put_u8(slabs.size())
		for w: int in slabs:
			out.put_u8(w)
	return out.data_array


## Names a ruleset in one number: the hash of its bytes.
func fingerprint() -> int:
	return SimConst.hash64(encode())


func duplicate() -> SimRules:
	return decode(encode())


## Reads and validates. null for anything that isn't a playable ruleset in this layout.
static func decode(bytes: PackedByteArray) -> SimRules:
	var r := _Reader.new(bytes)
	if r.take(4).get_string_from_ascii() != MAGIC or r.u8() != LAYOUT:
		return null
	var out := SimRules.new()
	out.colors = r.u8()
	var flags := r.u8()
	if flags > 7:
		return null
	out.manual_raise = flags & 1 != 0
	out.combos_send = flags & 2 != 0
	out.chains_send = flags & 4 != 0
	for t: Array in TIMINGS:
		out.set(t[0], r.s32())
	out.rise = _read_curve(r)
	out.chain_rows = _read_curve(r)
	out.combo_from = r.u8()
	var n := r.u8()
	out.combo = []
	for k in n:
		var slabs := []
		for j in r.u8():
			slabs.append(r.u8())
		out.combo.append(slabs)
	if r.bad or r.p != bytes.size() or out.rise == null or out.chain_rows == null:
		return null
	if out.validate() != "":
		return null
	return out


static func _read_curve(r: _Reader) -> Line:
	var fill := r.u8()
	var extend := r.u8()
	var n := r.u8()
	var points := []
	for k in n:
		points.append([r.s32(), r.s32()])
	if r.bad or fill > STEP or extend > 1:
		return null
	return Line.new(fill, extend == 1, points)


## Reads little-endian values; past the end it reads zeros and sets bad.
class _Reader:
	var b: PackedByteArray
	var p := 0
	var bad := false

	func _init(bytes: PackedByteArray) -> void:
		b = bytes

	func _have(n: int) -> bool:
		if bad or p + n > b.size():
			bad = true
			return false
		return true

	func take(n: int) -> PackedByteArray:
		if not _have(n):
			return PackedByteArray()
		p += n
		return b.slice(p - n, p)

	func u8() -> int:
		if not _have(1):
			return 0
		p += 1
		return b.decode_u8(p - 1)

	func s32() -> int:
		if not _have(4):
			return 0
		p += 4
		return b.decode_s32(p - 4)
