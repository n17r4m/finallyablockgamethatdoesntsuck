class_name SimConst
## Fixed sim parameters. All time is integer ticks at TICK_HZ — no floats in the sim, ever.
## Panel de Pon timings are given in 60 fps frames; 1 frame = 18 ticks.

const TICK_HZ := 1080
const TICKS_PER_FRAME := 18 # at 60 fps; 9 at 120, so both divide evenly
const W := 6
const H := 12 # visible rows
const BUF := 12 # hidden rows above the well where garbage spawns and stacks
const ROWS := BUF + H
const COLORS := 5
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

const REPEAT_DELAY := 180 # ~167 ms before cursor auto-repeat
const REPEAT_RATE := 54 # ~50 ms per repeat step

const SWAP_TICKS := 72 # 4 f
const HOVER_TICKS := 216 # 12 f: unsupported panels hang before falling
const FALL_TICKS := 18 # 1 f per cell
const LAND_TICKS := 108 # 6 f: landing squash (matchable, presentation only)
const FLASH_TICKS := 792 # 44 f: matched panels flash
const POP_TICKS := 162 # 9 f: then pop one at a time, vanishing together at the end
# Cracking garbage reveals in a ripple outward from where the match touched it.
const REVEAL_TICKS := 270 # 15 f per cell that reveals a panel: slow enough to read and react
const SHELL_POP_TICKS := 54 # 3 f per cell that stays garbage (upper rows)
const GARBAGE_HANG_TICKS := 432 # 24 f: revealed panels hang before dropping
# Bullet time: while garbage cracks, a board's world clock (falls, pops, rise, grace)
# slows to TIME_SLOW/TIME_UNIT; the player's clock (cursor, swaps) doesn't.
const TIME_UNIT := 16
const TIME_SLOW := 6 # 0.375x
const TIME_RAMP := 18 # ticks per 1/16 step when easing in or out (~10 frames end to end)

const ROW_UNITS := 6480 # one row per 6 s at base rise speed
const RAISE_SPEED := 40 # manual raise multiplier
const SPEEDUP_TICKS := 21600 # base rise speed +1 every 20 s of play, so games end
const STOP_TICKS := 1080 # rise pauses this long after a combo or chain link

const COUNTDOWN_TICKS := 3240 # 3 s; cursor moves, nothing else does
const HEALTH_TICKS := 2160 # 2 s of grace while the stack is pressed against the top

const GARBAGE_DELAY := 540 # ~0.5 s from being sent to dropping in
const GARBAGE_GAP := 135 # between consecutive slabs
const FX_TICKS := 1080 # how long combo/chain callouts stay up
# Combo size -> garbage slab widths sent (Panel de Pon table). Chains send
# full-width slabs (chain_n - 1) rows tall when the chain ends.
const COMBO_GARBAGE := {
	4: [3], 5: [4], 6: [5], 7: [6], 8: [3, 4], 9: [4, 4], 10: [5, 5], 11: [5, 6], 12: [6, 6],
}


## Input bits that put the cursor's left cell at (x, visible row y from the top).
static func target(x: int, y: int) -> int:
	return TARGET | (clampi(x, 0, W - 2) << 8) | (clampi(y, 0, H - 1) << 12)


## Garbage slabs travel as one int: width + height * 8.
static func slab(w: int, h: int) -> int:
	return w + h * 8
