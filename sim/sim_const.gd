class_name SimConst
## Fixed sim parameters. All time is integer ticks at TICK_HZ — no floats in the sim, ever.

const TICK_HZ := 1080
const TICKS_PER_FRAME := 18 # at 60 fps; 9 at 120, so both divide evenly
const W := 6
const H := 12
const COLORS := 5

# Input bitmask
const UP := 1
const DOWN := 2
const LEFT := 4
const RIGHT := 8
const SWAP := 16
const RAISE := 32
const DIRS := UP | DOWN | LEFT | RIGHT

const REPEAT_DELAY := 180 # ~167 ms before cursor auto-repeat
const REPEAT_RATE := 54 # ~50 ms per repeat step
const FALL_TICKS := 36 # one cell per ~33 ms
const CLEAR_TICKS := 720 # ~667 ms flash before matched blocks vanish
const ROW_UNITS := 6480 # one row per 6 s at base rise speed
const RAISE_SPEED := 40 # manual raise multiplier

const GARBAGE := 7 # cell value for garbage; colours are 1..COLORS
const GARBAGE_DELAY := 540 # ~0.5 s from being sent to dropping in
# Combo size -> garbage slab widths sent (Panel de Pon table).
const COMBO_GARBAGE := {
	4: [3], 5: [4], 6: [5], 7: [6], 8: [3, 4], 9: [4, 4], 10: [5, 5], 11: [5, 6], 12: [6, 6],
}
