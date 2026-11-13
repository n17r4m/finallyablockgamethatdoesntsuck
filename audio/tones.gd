class_name Tones
## Every sound the game makes, synthesised at start-up: no audio files, nothing to license.
## Each is a short mono AudioStreamWAV; pitch comes from the player's pitch_scale, so one pop
## plays a whole scale.

const RATE := 44100

static var _cache := {}


static func get_stream(name: String) -> AudioStreamWAV:
	if not _cache.has(name):
		_cache[name] = _wav(_make(name))
	return _cache[name]


static func names() -> PackedStringArray:
	return ["pop", "match", "chain", "swap", "move", "land", "thud", "crack", "reveal", "beep", "go",
			"heartbeat", "win", "lose"]


static func _make(name: String) -> PackedFloat32Array:
	match name:
		"pop": return _pop()
		"match": return _match()
		"chain": return _chain()
		"swap": return _swap()
		"move": return _move()
		"land": return _land()
		"thud": return _thud()
		"crack": return _crack()
		"reveal": return _reveal()
		"beep": return _beep()
		"go": return _go()
		"heartbeat": return _heartbeat()
		"win": return _win()
		"lose": return _lose()
	push_error("no tone called " + name)
	return _buf(0.01)


## A glass bubble: a bright partial that glides up as it bursts.
static func _pop() -> PackedFloat32Array:
	var out := _buf(0.22)
	var ph := 0.0
	for i in out.size():
		var t := float(i) / RATE
		var f := 587.33 * (1.0 + 0.12 * (1.0 - exp(-t * 30.0)))
		ph += TAU * f / RATE
		var env := _attack(t, 0.002) * exp(-t * 20.0)
		out[i] = env * (0.7 * sin(ph) + 0.22 * sin(2.0 * ph) * exp(-t * 30.0) + 0.08 * sin(3.0 * ph) * exp(-t * 50.0))
	return out


## Panels lock into a match: a soft major triad, plucked.
static func _match() -> PackedFloat32Array:
	return _chord([523.25, 659.26, 783.99], 0.45, 9.0, 0.5)


## A chain link: three quick notes up, then a ring.
static func _chain() -> PackedFloat32Array:
	var out := _buf(0.6)
	var notes := [659.26, 830.61, 987.77, 1318.51]
	for k in notes.size():
		_add_note(out, notes[k], k * 0.055, 0.5 if k == notes.size() - 1 else 0.18, 0.35)
	return out


static func _swap() -> PackedFloat32Array:
	var out := _buf(0.05)
	var ph := 0.0
	for i in out.size():
		var t := float(i) / RATE
		ph += TAU * lerpf(700.0, 1100.0, t / 0.05) / RATE
		out[i] = 0.35 * _attack(t, 0.001) * exp(-t * 70.0) * sin(ph)
	return out


static func _move() -> PackedFloat32Array:
	var out := _buf(0.02)
	for i in out.size():
		var t := float(i) / RATE
		out[i] = 0.18 * exp(-t * 300.0) * sin(TAU * 2200.0 * t)
	return out


static func _land() -> PackedFloat32Array:
	var out := _buf(0.08)
	var ph := 0.0
	for i in out.size():
		var t := float(i) / RATE
		ph += TAU * lerpf(260.0, 140.0, t / 0.08) / RATE
		out[i] = 0.45 * _attack(t, 0.001) * exp(-t * 45.0) * sin(ph)
	return out


## Garbage hits the stack.
static func _thud() -> PackedFloat32Array:
	var out := _buf(0.35)
	var noise := _noise(out.size(), 0.04, 7)
	var ph := 0.0
	for i in out.size():
		var t := float(i) / RATE
		ph += TAU * lerpf(110.0, 45.0, minf(t / 0.2, 1.0)) / RATE
		out[i] = _attack(t, 0.002) * (0.7 * exp(-t * 12.0) * sin(ph) + 0.25 * exp(-t * 25.0) * noise[i])
	return out


## Garbage starts to break.
static func _crack() -> PackedFloat32Array:
	var out := _buf(0.3)
	var noise := _noise(out.size(), 0.5, 11)
	for i in out.size():
		var t := float(i) / RATE
		out[i] = 0.55 * exp(-t * 14.0) * noise[i] + 0.25 * exp(-t * 20.0) * sin(TAU * 320.0 * t)
	return out


## One garbage cell turns into a panel.
static func _reveal() -> PackedFloat32Array:
	var out := _buf(0.06)
	for i in out.size():
		var t := float(i) / RATE
		out[i] = 0.3 * _attack(t, 0.001) * exp(-t * 60.0) * _tri(1175.0 * t)
	return out


static func _beep() -> PackedFloat32Array:
	return _chord([659.26], 0.16, 18.0, 0.5)


static func _go() -> PackedFloat32Array:
	return _chord([1318.51, 1975.53], 0.4, 7.0, 0.45)


## The stack is pressed against the top and health is draining.
static func _heartbeat() -> PackedFloat32Array:
	var out := _buf(0.32)
	for beat in [0.0, 0.15]:
		var ph := 0.0
		for i in int(0.12 * RATE):
			var t := float(i) / RATE
			var j := int(beat * RATE) + i
			ph += TAU * lerpf(90.0, 50.0, t / 0.12) / RATE
			out[j] += (0.8 if beat == 0.0 else 0.55) * _attack(t, 0.003) * exp(-t * 30.0) * sin(ph)
	return out


static func _win() -> PackedFloat32Array:
	var out := _buf(1.1)
	var notes := [523.25, 659.26, 783.99, 1046.5]
	for k in notes.size():
		_add_note(out, notes[k], k * 0.11, 0.7 if k == notes.size() - 1 else 0.3, 0.4)
	return out


static func _lose() -> PackedFloat32Array:
	var out := _buf(1.1)
	var notes := [392.0, 311.13, 261.63]
	for k in notes.size():
		_add_note(out, notes[k], k * 0.18, 0.8 if k == notes.size() - 1 else 0.3, 0.4)
	return out


static func _chord(freqs: Array, dur: float, decay: float, gain: float) -> PackedFloat32Array:
	var out := _buf(dur)
	for i in out.size():
		var t := float(i) / RATE
		var v := 0.0
		for f: float in freqs:
			v += sin(TAU * f * t) + 0.3 * sin(TAU * 2.0 * f * t) * exp(-t * 12.0)
		out[i] = gain * _attack(t, 0.003) * exp(-t * decay) * v / freqs.size()
	return out


static func _add_note(out: PackedFloat32Array, f: float, at: float, dur: float, gain: float) -> void:
	var start := int(at * RATE)
	for i in mini(int(dur * RATE), out.size() - start):
		var t := float(i) / RATE
		var env := _attack(t, 0.003) * exp(-t * 4.0 / dur)
		out[start + i] += gain * env * (sin(TAU * f * t) + 0.25 * sin(TAU * 2.0 * f * t) * exp(-t * 15.0))


static func _attack(t: float, len: float) -> float:
	return minf(t / len, 1.0)


static func _tri(cycles: float) -> float:
	return 4.0 * absf(fposmod(cycles, 1.0) - 0.5) - 1.0


## White noise through a one-pole low-pass; `smooth` near 0 is darker.
static func _noise(n: int, smooth: float, noise_seed: int) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = noise_seed
	var out := PackedFloat32Array()
	out.resize(n)
	var y := 0.0
	for i in n:
		y += smooth * (rng.randf_range(-1.0, 1.0) - y)
		out[i] = y / sqrt(smooth)
	return out


static func _buf(seconds: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(int(seconds * RATE))
	return out


static func _wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = bytes
	return w
