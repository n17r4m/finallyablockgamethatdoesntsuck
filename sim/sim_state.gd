class_name SimState
extends RefCounted
## The entire deterministic game: both wells and the tick counter.

var tick := 0
var boards: Array[SimBoard] = []


static func create(game_seed: int) -> SimState:
	var s := SimState.new()
	# Same seed for both wells so the garbage-free start is fair.
	s.boards.append(SimBoard.create(game_seed))
	s.boards.append(SimBoard.create(game_seed))
	return s


func step(input0: int, input1: int) -> void:
	boards[0].step(input0)
	boards[1].step(input1)
	tick += 1


func copy() -> SimState:
	var s := SimState.new()
	s.tick = tick
	s.boards.append(boards[0].copy())
	s.boards.append(boards[1].copy())
	return s


func checksum() -> int:
	return hash([tick, boards[0].checksum(), boards[1].checksum()])
