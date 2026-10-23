class_name CpuPlayer
extends RefCounted
## CPU opponent: anytime stochastic search over swap plans, on a fast model.
##
## Every frame it
##   1. projects the real board to how it will look once clears and falls settle
##      (a W x H byte grid; garbage is a fixed obstacle),
##   2. samples random swap sequences up to `depth` long — rollouts that pick
##      each step from the evolving model (every prefix is a candidate), and
##      mutations of current_plan — scoring each with instant cascade
##      resolution plus a board-shape heuristic,
##   3. keeps the best as current_plan if it beats the plan being executed
##      (re-scored on the fresh projection), and
##   4. walks the cursor to the plan's next swap and presses it.
## It only reads the board and returns an input mask, like a player would.
##
## Opponents = a personality (style weights + quirks) played at a level
## (skill: how well it searches and how fast its hands are). Noise doubles as eagerness: a
## noiseless searcher rarely finds a plan clearly better than waiting.

const W := SimConst.W
const H := SimConst.H
const TOP := SimConst.BUF
const GARBAGE := 7 # model: garbage, an obstacle that matches next to it hit
const BLOCK := 8 # model: solid and unknown (converting garbage)

const SKILLS := {
	"easy": {"depth": 1, "samples": 2, "step_frames": 9, "noise": 40.0, "raise": false},
	"normal": {"depth": 2, "samples": 4, "step_frames": 5, "noise": 14.0, "raise": true},
	"hard": {"depth": 2, "samples": 10, "step_frames": 2, "noise": 10.0, "raise": true},
	"max": {"depth": 3, "samples": 16, "step_frames": 1, "noise": 8.0, "raise": true},
}

## Score-function weights. clear/chain/combo/garbage reward outcomes; the rest shape the board.
const STYLES := {
	"balanced": {"clear": 10.0, "chain": 150.0, "combo": 40.0, "garbage": 15.0,
			"pairs": 2.0, "bump": 3.0, "height": 0.5, "danger": 40.0, "travel": 1.5},
	"chainer": {"clear": 6.0, "chain": 320.0, "combo": 20.0, "garbage": 10.0,
			"pairs": 4.0, "bump": 2.0, "height": 0.3, "danger": 40.0, "travel": 1.0},
	"comboer": {"clear": 10.0, "chain": 90.0, "combo": 140.0, "garbage": 15.0,
			"pairs": 3.0, "bump": 3.0, "height": 0.5, "danger": 40.0, "travel": 1.5},
	"turtle": {"clear": 14.0, "chain": 100.0, "combo": 30.0, "garbage": 45.0,
			"pairs": 1.0, "bump": 5.0, "height": 2.0, "danger": 90.0, "travel": 1.0},
}

## The roster: name -> {style, blurb, quirks (skill overrides at every level)}.
const OPPONENTS := {
	"Turtle": {"style": "turtle", "blurb": "Keeps a low stack and digs out every slab.", "quirks": {}},
	"Brawler": {"style": "comboer", "blurb": "Lives for the big combo.", "quirks": {}},
	"Architect": {"style": "chainer", "blurb": "Builds towers that fall into chains.", "quirks": {"depth": 3}},
	"Blitz": {"style": "balanced", "blurb": "Fast hands, shallow thoughts.", "quirks": {"depth": 1, "step_frames": 1}},
	"Overmind": {"style": "balanced", "blurb": "No quirks. Just good.", "quirks": {}},
}
const LEVELS := ["easy", "normal", "hard", "max"]

var depth: int # longest plan considered
var samples: int # plans sampled per frame
var step_frames: int # frames per cursor step / swap press
var noise: float # score jitter: higher = sloppier choices
var use_raise: bool
var w := {} # style weights

var current_plan: Array[Vector2i] = [] # swaps (left cell x, visible row y from top), next first
var current_value := -INF

var _rng := RandomNumberGenerator.new()
var _frame := 0
var _released := true
var _last_rise := 0
var _cursor := Vector2i.ZERO


func _init(skill: String, style: String, rng_seed: int) -> void:
	var p: Dictionary = SKILLS[skill]
	depth = p.depth
	samples = p.samples
	step_frames = p.step_frames
	noise = p.noise
	use_raise = p.raise
	w = STYLES[style].duplicate()
	_rng.seed = rng_seed


static func opponent(name: String, level: String, rng_seed: int) -> CpuPlayer:
	var o: Dictionary = OPPONENTS[name]
	var cpu := CpuPlayer.new(level, o.style, rng_seed)
	for k: String in o.quirks:
		cpu.set(k, o.quirks[k])
	return cpu


## Call once per frame with the board this CPU controls; returns its input mask.
func next_input(b: SimBoard) -> int:
	_frame += 1
	if b.rise < _last_rise:
		current_plan.clear() # the stack pushed up a row; plan coordinates are stale
	_last_rise = b.rise
	_cursor = Vector2i(b.cursor_x, b.cursor_y - TOP)
	var g := project(b)
	_think(g)
	return _act(b, g)


# --- search -------------------------------------------------------------------

func _think(g: PackedByteArray) -> void:
	var moves := _valid_swaps(g)
	var idle := evaluate(g, [])
	current_value = evaluate(g, current_plan) if not current_plan.is_empty() else -INF
	var best := current_plan
	var best_v := maxf(current_value, idle)
	if best_v == idle and current_value < idle:
		best = []
	if moves.is_empty():
		current_plan = best
		return
	for k in samples:
		var plan: Array[Vector2i]
		var v: float
		if not current_plan.is_empty() and _rng.randf() < 0.35:
			plan = _mutate(current_plan, moves)
			v = evaluate(g, plan)
		else:
			plan = []
			v = _rollout(g, plan)
		v += _rng.randf_range(-noise, noise)
		if v > best_v:
			best_v = v
			best = plan
	if best != current_plan:
		current_plan = best
		current_value = best_v


## Random walk of up to `depth` swaps, each drawn from the model as it evolves.
## Fills `plan` with the best-scoring prefix and returns its value.
func _rollout(g: PackedByteArray, plan: Array[Vector2i]) -> float:
	var m := g.duplicate()
	var total := 0.0
	var travel := 0
	var pos := _cursor
	var discount := 1.0
	var walk: Array[Vector2i] = []
	var best_v := -INF
	var best_len := 0
	for k in depth:
		var moves := _valid_swaps(m)
		if moves.is_empty():
			break
		var s := moves[_rng.randi() % moves.size()]
		_swap(m, s.x, s.y)
		walk.append(s)
		travel += absi(s.x - pos.x) + absi(s.y - pos.y)
		pos = s
		total += _reward(_resolve(m)) * discount
		discount *= 0.85
		var v: float = total + _shape(m) - travel * w.travel - walk.size() * 2.0
		if v > best_v:
			best_v = v
			best_len = walk.size()
	plan.assign(walk.slice(0, best_len))
	return best_v


func _mutate(plan: Array[Vector2i], moves: Array[Vector2i]) -> Array[Vector2i]:
	var p := plan.duplicate()
	var r := _rng.randi() % 3
	if r == 0 or p.size() >= depth:
		p[_rng.randi() % p.size()] = moves[_rng.randi() % moves.size()]
	elif r == 1:
		p.append(moves[_rng.randi() % moves.size()])
	elif p.size() > 1:
		p.remove_at(p.size() - 1)
	return p


## Score of executing `plan` on model grid g: discounted cascade rewards,
## final board shape, minus cursor travel.
func evaluate(g: PackedByteArray, plan: Array[Vector2i]) -> float:
	var m := g.duplicate()
	var total := 0.0
	var travel := 0
	var pos := _cursor
	var discount := 1.0
	for s in plan:
		if not _swap(m, s.x, s.y):
			return -INF
		travel += absi(s.x - pos.x) + absi(s.y - pos.y)
		pos = s
		total += _reward(_resolve(m)) * discount
		discount *= 0.85
	return total + _shape(m) - travel * w.travel - plan.size() * 2.0


## Vector4i(chain links, panels cleared, biggest combo, garbage cells hit)
func _reward(r: Vector4i) -> float:
	var v: float = r.y * w.clear + r.w * w.garbage
	if r.x >= 2:
		v += w.chain * (r.x - 1) * (r.x - 1)
	if r.z >= 4:
		v += w.combo * (r.z - 3)
	return v


func _shape(m: PackedByteArray) -> float:
	var heights := PackedInt32Array()
	heights.resize(W)
	var pairs := 0
	for x in W:
		for y in H:
			if m[y * W + x] != 0:
				heights[x] = H - y
				break
	for y in H:
		for x in W:
			var c := m[y * W + x]
			if c == 0 or c > SimConst.COLORS:
				continue
			if x < W - 1 and m[y * W + x + 1] == c:
				pairs += 1
			if y < H - 1 and m[(y + 1) * W + x] == c:
				pairs += 1
	var bump := 0
	var total := 0
	var top := 0
	for x in W:
		total += heights[x]
		top = maxi(top, heights[x])
		if x > 0:
			bump += absi(heights[x] - heights[x - 1])
	var danger := maxi(top - 7, 0)
	return pairs * w.pairs - bump * w.bump - total * w.height - danger * danger * w.danger


# --- model --------------------------------------------------------------------

## The real board as it will be once current clears and falls play out.
func project(b: SimBoard) -> PackedByteArray:
	var g := PackedByteArray()
	g.resize(W * H)
	for i in W * H:
		var r := TOP * W + i
		var c := b.color[r]
		if c == 0:
			continue
		if b.gid[r] != 0:
			g[i] = BLOCK if b.st[r] == SimBoard.MATCHED else GARBAGE
		elif b.st[r] != SimBoard.MATCHED:
			g[i] = c
	_gravity(g)
	_resolve(g) # a chain already in flight isn't the plan's doing
	return g


func _valid_swaps(g: PackedByteArray) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in H:
		for x in W - 1:
			var a := g[y * W + x]
			var c := g[y * W + x + 1]
			if a != c and a <= SimConst.COLORS and c <= SimConst.COLORS:
				out.append(Vector2i(x, y))
	return out


func _swap(m: PackedByteArray, x: int, y: int) -> bool:
	var i := y * W + x
	var a := m[i]
	var c := m[i + 1]
	if a == c or a > SimConst.COLORS or c > SimConst.COLORS:
		return false
	m[i] = c
	m[i + 1] = a
	_gravity(m)
	return true


## Panels fall; garbage and blocks stay put and hold up what's above them.
func _gravity(m: PackedByteArray) -> void:
	for x in W:
		var write := H - 1
		for y in range(H - 1, -1, -1):
			var c := m[y * W + x]
			if c == 0:
				continue
			if c > SimConst.COLORS:
				write = y - 1
			else:
				if write != y:
					m[write * W + x] = c
					m[y * W + x] = 0
				write -= 1


## Clears matches and cascades until stable.
func _resolve(m: PackedByteArray) -> Vector4i:
	var links := 0
	var cleared := 0
	var combo := 0
	var hits := 0
	var mark := PackedByteArray()
	mark.resize(W * H)
	while true:
		mark.fill(0)
		var n := 0
		for y in H:
			for x in W:
				var c := m[y * W + x]
				if c == 0 or c > SimConst.COLORS:
					continue
				if x <= W - 3 and m[y * W + x + 1] == c and m[y * W + x + 2] == c:
					mark[y * W + x] = 1
					mark[y * W + x + 1] = 1
					mark[y * W + x + 2] = 1
				if y <= H - 3 and m[(y + 1) * W + x] == c and m[(y + 2) * W + x] == c:
					mark[y * W + x] = 1
					mark[(y + 1) * W + x] = 1
					mark[(y + 2) * W + x] = 1
		for i in W * H:
			if mark[i]:
				n += 1
				var x := i % W
				for j: int in [i - W, i + W, i - 1 if x > 0 else -1, i + 1 if x < W - 1 else -1]:
					if j >= 0 and j < W * H and m[j] == GARBAGE:
						hits += 1
				m[i] = 0
		if n == 0:
			break
		links += 1
		cleared += n
		combo = maxi(combo, n)
		_gravity(m)
	return Vector4i(links, cleared, combo, hits)


# --- execution ----------------------------------------------------------------

func _act(b: SimBoard, g: PackedByteArray) -> int:
	var held := 0
	if use_raise and not b.has_matched and b.chain_n == 1 and b.gar_q.is_empty() and _stack_height(g) < 4:
		held = SimConst.RAISE
	# Alternate press / release so every step is a fresh edge.
	if not _released or _frame % step_frames != 0:
		_released = true
		return held
	if current_plan.is_empty():
		return held
	var t := current_plan[0]
	var dir := 0
	if t.y < _cursor.y:
		dir = SimConst.UP
	elif t.y > _cursor.y:
		dir = SimConst.DOWN
	elif t.x < _cursor.x:
		dir = SimConst.LEFT
	elif t.x > _cursor.x:
		dir = SimConst.RIGHT
	if dir != 0:
		_released = false
		return dir | held
	var i := b.cursor_y * W + b.cursor_x
	if not (_swappable(b, i) and _swappable(b, i + 1) and _calm_above(b, i) and _calm_above(b, i + 1)):
		return held # cells busy, or something is still coming down onto them; wait
	current_plan.remove_at(0)
	_released = false
	return SimConst.SWAP | held


func _swappable(b: SimBoard, i: int) -> bool:
	return b.color[i] == 0 or (b.gid[i] == 0 and (b.st[i] == SimBoard.NORMAL or b.st[i] == SimBoard.LAND))


## Nothing above cell i in its column is hovering or falling, so the model's
## assumption that it has landed holds.
func _calm_above(b: SimBoard, i: int) -> bool:
	var j := i - W
	while j >= 0:
		if b.st[j] == SimBoard.HOVER or b.st[j] == SimBoard.FALL:
			return false
		j -= W
	return true


func _stack_height(g: PackedByteArray) -> int:
	for y in H:
		for x in W:
			if g[y * W + x] != 0:
				return H - y
	return 0
