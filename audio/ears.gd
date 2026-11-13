class_name Ears
## Listens to one board from frame to frame and says what was heard: [name, value] pairs that
## Sfx plays. Only the board as shown is compared, so a rollback that predicted right stays
## silent, and one that predicted wrong at worst plays a sound early or twice.
##
## Events: ["move"], ["swap"], ["land"], ["match", panels], ["chain", length], ["pop", step],
## ["crack"], ["reveal", step], ["thud", cells], ["heartbeat"], ["lost"].

const MAX_POPS := 4 # per frame; any more are one chord anyway
const HEARTBEAT_TICKS := 360 # one beat per half second of health lost

var _st := PackedByteArray()
var _was_garbage := PackedByteArray()
var _shown := PackedByteArray() # 1: the cell is popping (or revealing) already
var _swaps := 0
var _cursor := Vector2i(-1, -1)
var _health := 0
var _lost := false
var _pop_step := 0 # how far up the scale this run of pops has climbed
var _reveal_step := 0
var _fresh := true


func hear(b: SimBoard) -> Array:
	var out := []
	if _fresh or b.st.size() != _st.size():
		_take(b)
		return out
	var matched := 0
	var cracked := 0
	var landed := 0
	var thuds := 0
	var pops := 0
	var reveals := 0
	var any_matched := false
	var any_cracking := false
	var shown := PackedByteArray()
	shown.resize(b.st.size())
	for i in b.st.size():
		var s := b.st[i]
		var was := _st[i]
		var garbage := b.gid[i] != 0
		if s == SimBoard.MATCHED:
			if garbage:
				any_cracking = true
			else:
				any_matched = true
			if was != SimBoard.MATCHED:
				if garbage:
					cracked += 1
				else:
					matched += 1
			if b.tm[i] <= (b.aux[i] & 0xFFFF):
				shown[i] = 1
				if _shown[i] == 0:
					if garbage:
						reveals += 1
					else:
						pops += 1
		elif was == SimBoard.MATCHED and _shown[i] == 0:
			# The last panel of a match pops on the tick they all clear.
			if _was_garbage[i]:
				reveals += 1
			else:
				pops += 1
		if s == SimBoard.LAND and was != SimBoard.LAND:
			landed += 1
		elif garbage and was == SimBoard.FALL and s != SimBoard.FALL:
			thuds += 1
	if b.swaps > _swaps:
		out.append(["swap"])
	elif Vector2i(b.cursor_x, b.cursor_y) != _cursor:
		out.append(["move"])
	if matched > 0:
		if b.chain_n > 1:
			out.append(["chain", b.chain_n])
		else:
			out.append(["match", matched])
	if cracked > 0:
		out.append(["crack"])
	if not any_matched:
		_pop_step = 0
	if not any_cracking:
		_reveal_step = 0
	for k in mini(pops, MAX_POPS):
		out.append(["pop", _pop_step + (b.chain_n - 1) * 2])
		_pop_step += 1
	_pop_step += maxi(pops - MAX_POPS, 0)
	for k in mini(reveals, MAX_POPS):
		out.append(["reveal", _reveal_step])
		_reveal_step += 1
	if thuds > 0:
		out.append(["thud", thuds])
	elif landed > 0:
		out.append(["land"])
	if b.health < _health and b.health / HEARTBEAT_TICKS != _health / HEARTBEAT_TICKS:
		out.append(["heartbeat"])
	if b.lost and not _lost:
		out.append(["lost"])
	_take(b)
	_shown = shown
	return out


func _take(b: SimBoard) -> void:
	_st = b.st.duplicate()
	_was_garbage.resize(_st.size())
	for i in _st.size():
		_was_garbage[i] = 1 if b.gid[i] != 0 else 0
	if _fresh or _shown.size() != _st.size():
		_shown = PackedByteArray()
		_shown.resize(_st.size())
	_swaps = b.swaps
	_cursor = Vector2i(b.cursor_x, b.cursor_y)
	_health = b.health
	_lost = b.lost
	_fresh = false
