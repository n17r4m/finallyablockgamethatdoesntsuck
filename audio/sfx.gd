class_name Sfx
extends Node
## Plays what Ears hear on each board, plus the match's countdown and ending, on the SFX bus.
## The other player's board is quieter and doesn't click with every cursor move.

const VOICES := 24
## Pops and reveals climb this scale, in semitones, one step per panel.
const SCALE := [0, 2, 4, 7, 9, 12, 14, 16, 19, 21, 24] # two octaves; longer runs stay on top
const OTHER_DB := -9.0
const GAIN_DB := {"pop": -4.0, "match": -8.0, "chain": -5.0, "swap": -10.0, "move": -16.0,
		"land": -12.0, "thud": -3.0, "crack": -6.0, "reveal": -9.0, "beep": -8.0, "go": -6.0,
		"heartbeat": -2.0, "win": -5.0, "lose": -5.0}

var local_idx := 0
var _ears: Array[Ears] = []
var _voices: Array[AudioStreamPlayer] = []
var _next := 0
var _count := -1 # countdown seconds last announced
var _winner := -1


func _ready() -> void:
	for k in VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX" if AudioServer.get_bus_index("SFX") != -1 else "Master"
		add_child(p)
		_voices.append(p)


## Call once a frame with the state being shown.
func listen(state: SimState) -> void:
	while _ears.size() < state.boards.size():
		_ears.append(Ears.new())
	for p in state.boards.size():
		if state.solo and p != 0:
			continue
		var mine := p == local_idx
		for e: Array in _ears[p].hear(state.boards[p]):
			_play_event(e, mine)
	_clock(state)


func _clock(state: SimState) -> void:
	var left := state.rules.countdown - state.tick
	var secs := ceili(float(left) / SimConst.TICK_HZ) if left > 0 else 0
	if secs != _count:
		if _count != -1 and secs < _count:
			play("go" if secs == 0 else "beep")
		_count = secs
	if state.winner != _winner:
		if _winner == -1 and state.winner != -1:
			play("win" if state.winner == local_idx or state.solo and state.winner == 0 else "lose")
		_winner = state.winner


func _play_event(e: Array, mine: bool) -> void:
	var db := 0.0 if mine else OTHER_DB
	match e[0]:
		"move":
			if mine:
				play("move", 0, db)
		"swap":
			if mine:
				play("swap", 0, db)
		"pop", "reveal":
			play(e[0], _note(e[1]), db)
		"match":
			play("match", 0, db + minf((e[1] - 3) * 1.0, 6.0))
		"chain":
			play("chain", (e[1] - 2) * 2, db + 2.0)
		"thud":
			play("thud", -mini(e[1] / 6, 5), db)
		"heartbeat":
			if mine:
				play("heartbeat", 0, db)
		"lost":
			pass # the match's ending plays instead
		_:
			play(e[0], 0, db)


static func _note(step: int) -> int:
	return SCALE[clampi(step, 0, SCALE.size() - 1)]


func play(sound: String, semitones := 0, db := 0.0) -> void:
	if _voices.is_empty():
		return
	var v := _voices[_next]
	_next = (_next + 1) % _voices.size()
	v.stream = Tones.get_stream(sound)
	v.pitch_scale = pow(2.0, clampi(semitones, -24, 36) / 12.0)
	v.volume_db = GAIN_DB.get(sound, 0.0) + db
	v.play()
