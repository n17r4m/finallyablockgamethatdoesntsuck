//! Fixed sim parameters. All time is integer ticks at `TICK_HZ`, and there are no floats in
//! the sim. These mirror `sim/sim_const.gd`; a difference fails the golden replays.

pub const RULES_VERSION: u16 = 1;
pub const TICK_HZ: u16 = 720;
pub const W: usize = 6;
pub const H: usize = 12; // visible rows
pub const BUF: usize = 12; // hidden rows above the well
pub const ROWS: usize = BUF + H;
pub const N: usize = W * ROWS;
pub const TOP: usize = BUF; // first visible row
pub const COLORS: u8 = 5;
pub const GARBAGE: u8 = 7;

pub const UP: u32 = 1;
pub const DOWN: u32 = 2;
pub const LEFT: u32 = 4;
pub const RIGHT: u32 = 8;
pub const SWAP: u32 = 16;
pub const RAISE: u32 = 32;
pub const DIRS: u32 = UP | DOWN | LEFT | RIGHT;
pub const TARGET: u32 = 1 << 16;
pub const TARGET_MASK: u32 = TARGET | (0x7 << 8) | (0xF << 12);
pub const INPUT_BITS: u32 = DIRS | SWAP | RAISE | TARGET_MASK;

// The timings, speeds, colours and garbage below are the standard ruleset's values. The sim reads
// them through `Rules` (each board's rules), so a custom game can change them.
pub const REPEAT_DELAY: i64 = 120;
pub const REPEAT_RATE: i64 = 36;

pub const SWAP_TICKS: i32 = 48;
pub const HOVER_TICKS: i32 = 144;
pub const FALL_TICKS: i32 = 12;
pub const LAND_TICKS: i32 = 72;
pub const FLASH_TICKS: i32 = 528;
pub const POP_TICKS: i32 = 108;
pub const REVEAL_TICKS: i32 = 180;
pub const SHELL_POP_TICKS: i32 = 36;
pub const GARBAGE_HANG_TICKS: i32 = 288;
pub const TIME_UNIT: i64 = 16;
pub const TIME_SLOW: i64 = 6;
pub const TIME_RAMP: i64 = 12;

pub const ROW_UNITS: i64 = 4320;
pub const RAISE_SPEED: i64 = 40;
pub const SPEEDUP_TICKS: i64 = 14400;
pub const STOP_TICKS: i64 = 720;

pub const COUNTDOWN_TICKS: i64 = 2160;
pub const HEALTH_TICKS: i64 = 1440;

pub const GARBAGE_DELAY: i64 = 360;
pub const GARBAGE_GAP: i64 = 90;
pub const FX_TICKS: i64 = 720;

/// Garbage slab widths sent by a combo of `n` panels (`n` is at least 4).
pub fn combo_garbage(n: usize) -> &'static [i32] {
    match n {
        4 => &[3],
        5 => &[4],
        6 => &[5],
        7 => &[6],
        8 => &[3, 4],
        9 => &[4, 4],
        10 => &[5, 5],
        11 => &[5, 6],
        12 => &[6, 6],
        _ => &[6, 6, 6],
    }
}

/// Garbage slabs travel as one int: width + height * 8.
pub fn slab(w: i32, h: i32) -> i32 {
    w + h * 8
}

/// Input bits that put the cursor's left cell at (x, visible row y from the top).
pub fn target(x: u32, y: u32) -> u32 {
    TARGET | (x.min(W as u32 - 2) << 8) | (y.min(H as u32 - 1) << 12)
}
