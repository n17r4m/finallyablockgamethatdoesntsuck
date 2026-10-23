class_name SimState
extends RefCounted
## The entire deterministic game: both wells, the tick counter and the result.

var tick := 0
var boards: Array[SimBoard] = []
var solo := false # practice: only board 0 plays
var winner := -1 # -1 playing, 0/1 that board won, 2 draw


static func create(game_seed: int, solo_mode := false) -> SimState:
	var s := SimState.new()
	s.solo = solo_mode
	# Same seed for both wells so the start is fair.
	s.boards.append(SimBoard.create(game_seed))
	s.boards.append(SimBoard.create(game_seed))
	return s


func step(input0: int, input1: int) -> void:
	if winner == -1:
		var live := tick >= SimConst.COUNTDOWN_TICKS
		boards[0].step(input0, live)
		if not solo:
			boards[1].step(input1, live)
		for p in 2:
			if not boards[p].outbox.is_empty():
				if not solo:
					boards[1 - p].receive_garbage(boards[p].outbox)
				boards[p].outbox.clear()
		if boards[0].lost or boards[1].lost:
			winner = 2 if boards[0].lost and boards[1].lost else (1 if boards[0].lost else 0)
	tick += 1


func copy() -> SimState:
	var s := SimState.new()
	s.tick = tick
	s.solo = solo
	s.winner = winner
	s.boards.append(boards[0].copy())
	s.boards.append(boards[1].copy())
	return s


func checksum() -> int:
	return hash([tick, solo, winner, boards[0].checksum(), boards[1].checksum()])
