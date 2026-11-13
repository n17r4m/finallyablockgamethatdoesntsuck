class_name SimConst
## Fixed sim parameters. All time is integer ticks at TICK_HZ — no floats in the sim, ever.
## Panel de Pon timings are given in 60 fps frames; 1 frame = 12 ticks.
## 720 divides evenly by 60, 72, 90, 120, 144, 180, 240 and 360, so those displays get a
## steady number of ticks per frame. Any other rate still works, off the wall clock.

## Bump whenever a rule or timing changes what a game does: old replays stop verifying,
## tools/make_golden.gd must be rerun, and rust/sim must change too. See docs/engine-contract.md.
const RULES_VERSION := 1
const TICK_HZ := 720
const TICKS_PER_FRAME := 12 # at 60 fps
const W := 6
const H := 12 # visible rows
const BUF := 12 # hidden rows above the well where garbage spawns and stacks
const ROWS := BUF + H
const COLORS := 5
## Seats in a match. A limit of cost, not of the game: every client rolls back every board, and
## eight boards at 720 Hz is about what a phone can resimulate. Battle royale needs its own
## coupling past this (docs/game-modes.md).
const MAX_SEATS := 8
const GARBAGE := 7 # cell colour value for garbage; panels are 1..COLORS

# Input bitmask
const UP := 1
const DOWN := 2
const LEFT := 4
const RIGHT := 8
const SWAP := 16
const RAISE := 32
const DIRS := UP | DOWN | LEFT | RIGHT
# Absolute cursor placement (touch/mouse): flag + left cell x (3 bits) + visible row y (4 bits).
const TARGET := 1 << 16
const TARGET_MASK := TARGET | (0x7 << 8) | (0xF << 12)
const INPUT_BITS := DIRS | SWAP | RAISE | TARGET_MASK # anything else is not an input

# The timings, speeds, colours and garbage below are the standard ruleset's values. The sim reads
# them through SimRules (each board's rules), so a custom game can change them.
const REPEAT_DELAY := 120 # ~167 ms before cursor auto-repeat
const REPEAT_RATE := 36 # ~50 ms per repeat step

const SWAP_TICKS := 48 # 4 f
const HOVER_TICKS := 144 # 12 f: unsupported panels hang before falling
const FALL_TICKS := 12 # 1 f per cell
const LAND_TICKS := 72 # 6 f: landing squash (matchable, presentation only)
const FLASH_TICKS := 528 # 44 f: matched panels flash
const POP_TICKS := 108 # 9 f: then pop one at a time, vanishing together at the end
# Cracking garbage reveals in a ripple outward from where the match touched it.
const REVEAL_TICKS := 180 # 15 f per cell that reveals a panel: slow enough to read and react
const SHELL_POP_TICKS := 36 # 3 f per cell that stays garbage (upper rows)
const GARBAGE_HANG_TICKS := 288 # 24 f: revealed panels hang before dropping
# Bullet time: while garbage cracks, a board's world clock (falls, pops, rise, grace)
# slows to TIME_SLOW/TIME_UNIT; the player's clock (cursor, swaps) doesn't.
const TIME_UNIT := 16
const TIME_SLOW := 6 # 0.375x
const TIME_RAMP := 12 # ticks per 1/16 step when easing in or out (~10 frames end to end)

const ROW_UNITS := 4320 # one row per 6 s at base rise speed
const RAISE_SPEED := 40 # manual raise multiplier
const SPEEDUP_TICKS := 14400 # base rise speed +1 every 20 s of play, so games end
const STOP_TICKS := 720 # rise pauses this long after a combo or chain link

const COUNTDOWN_TICKS := 2160 # 3 s; cursor moves, nothing else does
const HEALTH_TICKS := 1440 # 2 s of grace while the stack is pressed against the top

const GARBAGE_DELAY := 360 # ~0.5 s from being sent to dropping in
const GARBAGE_GAP := 90 # between consecutive slabs
const FX_TICKS := 720 # how long combo/chain callouts stay up
# Combo size -> garbage slab widths sent (Panel de Pon table). Chains send
# full-width slabs (chain_n - 1) rows tall when the chain ends.
const COMBO_GARBAGE := {
	4: [3], 5: [4], 6: [5], 7: [6], 8: [3, 4], 9: [4, 4], 10: [5, 5], 11: [5, 6], 12: [6, 6],
}


## Input bits that put the cursor's left cell at (x, visible row y from the top).
static func target(x: int, y: int) -> int:
	return TARGET | (clampi(x, 0, W - 2) << 8) | (clampi(y, 0, H - 1) << 12)


## First 8 bytes of SHA-256, read little-endian. Any language can reproduce this exactly.
static func hash64(bytes: PackedByteArray) -> int:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(bytes)
	return h.finish().decode_s64(0)


## Garbage slabs travel as one int: width + height * 8.
static func slab(w: int, h: int) -> int:
	return w + h * 8
