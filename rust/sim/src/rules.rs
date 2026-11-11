//! A ruleset: every number a match is played with that isn't the shape of the well or the tick
//! rate. `Rules::standard()` is the game as it has always played. `sim/sim_rules.gd` is the
//! other copy, and the byte layout in `docs/engine-contract.md` is what both must agree on.
//!
//! Zero, one or infinity: each limit below exists because something breaks without it, and says
//! what. "Forever" is `MAX_TICKS`, the longest game a replay may hold; a longer time can't be
//! told apart from forever.

use crate::consts::*;
use crate::hash64;
use crate::replay::MAX_TICKS;
use std::sync::{Arc, OnceLock};

pub const LAYOUT: u8 = 1;
const MAGIC: &[u8; 4] = b"FBRU";

/// Longest timing that still means something: past the longest game, it's forever.
pub const FOREVER: i32 = MAX_TICKS as i32;
/// Pop and reveal times add up across a whole match or slab (up to `N` cells), and the sum
/// shares a 32-bit cell with another timer, 16 bits each.
pub const MAX_POP: i32 = (i16::MAX as i32) / N as i32;
/// Cell value 7 is garbage, so panels are 1 to 6.
pub const MAX_COLORS: u8 = GARBAGE - 1;

/// How a curve fills in between its points.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Fill {
    Linear = 0,
    Step = 1,
}

/// A value that depends on another: points `(x, y)` with x strictly increasing. Before the first
/// point it's the first y. After the last it holds, or, with `extend`, carries on the way the last
/// two points go. All integers, so every implementation gets the same answer.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Curve {
    pub fill: Fill,
    pub extend: bool,
    pub points: Vec<(i32, i32)>,
}

/// A byte counts the points.
pub const MAX_POINTS: usize = u8::MAX as usize;

impl Curve {
    pub fn at(&self, x: i64) -> i64 {
        let p = &self.points;
        let (x0, y0) = (p[0].0 as i64, p[0].1 as i64);
        if x <= x0 || p.len() == 1 {
            return y0;
        }
        for w in p.windows(2) {
            let (ax, ay, bx, by) = (w[0].0 as i64, w[0].1 as i64, w[1].0 as i64, w[1].1 as i64);
            if x < bx {
                return match self.fill {
                    Fill::Step => ay,
                    Fill::Linear => ay + (by - ay) * (x - ax) / (bx - ax),
                };
            }
        }
        let n = p.len();
        let (ax, ay, bx, by) = (p[n - 2].0 as i64, p[n - 2].1 as i64, p[n - 1].0 as i64, p[n - 1].1 as i64);
        if !self.extend {
            return by;
        }
        // Validated points and a game's ages are all under 2^23, so no product nears i64's edge.
        let (dx, dy) = (bx - ax, by - ay);
        match self.fill {
            Fill::Step => by + (x - bx) / dx * dy,
            Fill::Linear => by + (x - bx) * dy / dx,
        }
    }

    fn check(&self, what: &str, x_min: i32, y_min: i32, y_max: i32) -> Result<(), String> {
        if self.points.is_empty() || self.points.len() > MAX_POINTS {
            return Err(format!("{what}: needs 1 to {MAX_POINTS} points"));
        }
        if self.extend && self.points.len() < 2 {
            return Err(format!("{what}: carrying on needs two points to follow"));
        }
        for (k, &(x, y)) in self.points.iter().enumerate() {
            if x < x_min || x > FOREVER {
                return Err(format!("{what}: point {k} is at {x}, outside {x_min} to {FOREVER}"));
            }
            if y < y_min || y > y_max {
                return Err(format!("{what}: point {k} is {y}, outside {y_min} to {y_max}"));
            }
            if k > 0 && x <= self.points[k - 1].0 {
                return Err(format!("{what}: points must go left to right"));
            }
        }
        Ok(())
    }

    fn write(&self, out: &mut Vec<u8>) {
        out.push(self.fill as u8);
        out.push(self.extend as u8);
        out.push(self.points.len() as u8);
        for &(x, y) in &self.points {
            out.extend_from_slice(&x.to_le_bytes());
            out.extend_from_slice(&y.to_le_bytes());
        }
    }

    fn read(r: &mut Reader) -> Option<Curve> {
        let fill = match r.u8()? {
            0 => Fill::Linear,
            1 => Fill::Step,
            _ => return None,
        };
        let extend = r.bool()?;
        let n = r.u8()? as usize;
        let mut points = Vec::with_capacity(n);
        for _ in 0..n {
            points.push((r.i32()?, r.i32()?));
        }
        Some(Curve { fill, extend, points })
    }
}

/// Every number a match plays by. Timings are in ticks.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Rules {
    pub colors: u8,
    pub manual_raise: bool,
    pub combos_send: bool,
    pub chains_send: bool,

    pub swap: i32,
    pub hover: i32,
    pub fall: i32,
    pub land: i32,
    pub flash: i32,
    pub pop: i32,
    pub reveal: i32,
    pub shell_pop: i32,
    pub garbage_hang: i32,
    pub repeat_delay: i32,
    pub repeat_rate: i32,
    pub time_slow: i32, // the world's speed while garbage cracks, in sixteenths
    pub time_ramp: i32,
    pub row_units: i32, // rise needed for one row
    pub raise_speed: i32,
    pub stop: i32,
    pub countdown: i32,
    pub health: i32,
    pub garbage_delay: i32,
    pub garbage_gap: i32,

    /// Rise per tick against the board's age.
    pub rise: Curve,
    /// Rows of full-width garbage a chain sends when it ends, against its length.
    pub chain_rows: Curve,
    /// Slab widths sent by a clear of `combo_from` panels, then one more, and so on. The last
    /// entry is for every bigger clear.
    pub combo_from: u8,
    pub combo: Vec<Vec<u8>>,
}

/// The most bytes a valid ruleset can take: every curve and table at its longest.
pub const MAX_BYTES: usize = 4 + 3 + 20 * 4 + 2 * (3 + MAX_POINTS * 8) + 2 + MAX_ENTRIES * (1 + MAX_ENTRIES);

/// A clear is at least three panels.
pub const MIN_CLEAR: u8 = 3;
/// A byte counts entries, and a byte counts the slabs in each.
pub const MAX_ENTRIES: usize = u8::MAX as usize;

impl Rules {
    pub fn standard() -> Rules {
        Rules {
            colors: COLORS,
            manual_raise: true,
            combos_send: true,
            chains_send: true,
            swap: SWAP_TICKS,
            hover: HOVER_TICKS,
            fall: FALL_TICKS,
            land: LAND_TICKS,
            flash: FLASH_TICKS,
            pop: POP_TICKS,
            reveal: REVEAL_TICKS,
            shell_pop: SHELL_POP_TICKS,
            garbage_hang: GARBAGE_HANG_TICKS,
            repeat_delay: REPEAT_DELAY as i32,
            repeat_rate: REPEAT_RATE as i32,
            time_slow: TIME_SLOW as i32,
            time_ramp: TIME_RAMP as i32,
            row_units: ROW_UNITS as i32,
            raise_speed: RAISE_SPEED as i32,
            stop: STOP_TICKS as i32,
            countdown: COUNTDOWN_TICKS as i32,
            health: HEALTH_TICKS as i32,
            garbage_delay: GARBAGE_DELAY as i32,
            garbage_gap: GARBAGE_GAP as i32,
            // 1 + age / SPEEDUP_TICKS
            rise: Curve { fill: Fill::Step, extend: true, points: vec![(0, 1), (SPEEDUP_TICKS as i32, 2)] },
            // chain length - 1
            chain_rows: Curve { fill: Fill::Linear, extend: true, points: vec![(1, 0), (2, 1)] },
            combo_from: 4,
            combo: (4..=13).map(|n| combo_garbage(n).iter().map(|&w| w as u8).collect()).collect(),
        }
    }

    /// The scalar timings in layout order, with their limits and why.
    fn timings(&self) -> [(&'static str, i32, i32, i32); 20] {
        let cell = 1; // a cell's timer counts down to exactly zero, so it must start above it
        [
            ("swap", self.swap, cell, FOREVER),
            ("hover", self.hover, cell, FOREVER),
            ("fall", self.fall, cell, FOREVER),
            ("land", self.land, cell, FOREVER),
            ("flash", self.flash, cell, FOREVER),
            ("pop", self.pop, cell, MAX_POP),
            ("reveal", self.reveal, cell, MAX_POP),
            ("shell_pop", self.shell_pop, cell, MAX_POP),
            ("garbage_hang", self.garbage_hang, cell, FOREVER),
            ("repeat_delay", self.repeat_delay, 0, FOREVER),
            ("repeat_rate", self.repeat_rate, 1, FOREVER), // repeats every this many ticks
            ("time_slow", self.time_slow, 1, TIME_UNIT as i32), // at 0 the crack never ends
            ("time_ramp", self.time_ramp, 0, FOREVER),
            ("row_units", self.row_units, 1, FOREVER),
            ("raise_speed", self.raise_speed, 0, FOREVER),
            ("stop", self.stop, 0, FOREVER),
            ("countdown", self.countdown, 0, FOREVER),
            ("health", self.health, 0, FOREVER),
            ("garbage_delay", self.garbage_delay, 0, FOREVER),
            ("garbage_gap", self.garbage_gap, 0, FOREVER),
        ]
    }

    /// Ok if the sim can play these rules: every game ends, and nothing overflows.
    pub fn validate(&self) -> Result<(), String> {
        if self.colors < 1 || self.colors > MAX_COLORS {
            return Err(format!("colours: 1 to {MAX_COLORS}"));
        }
        for (name, v, lo, hi) in self.timings() {
            if v < lo || v > hi {
                return Err(format!("{name}: {v} is outside {lo} to {hi}"));
            }
        }
        self.rise.check("rise", 0, 0, FOREVER)?;
        self.chain_rows.check("chain_rows", 1, 0, BUF as i32)?; // a chain is 2 or longer; 1 anchors the line
        if self.combo_from < MIN_CLEAR {
            return Err(format!("combo table: starts at {MIN_CLEAR} or more, the smallest clear"));
        }
        if self.combo.is_empty() || self.combo.len() > MAX_ENTRIES {
            return Err(format!("combo table: 1 to {MAX_ENTRIES} entries"));
        }
        for (k, slabs) in self.combo.iter().enumerate() {
            if slabs.len() > MAX_ENTRIES {
                return Err(format!("combo table: entry {k} has more than {MAX_ENTRIES} slabs"));
            }
            if slabs.iter().any(|&w| w < 1 || w as usize > W) {
                return Err(format!("combo table: entry {k}: slabs are 1 to {W} wide"));
            }
        }
        Ok(())
    }

    /// Rise this tick, at this age. Held to forever per tick, so a sum over a game fits in i64.
    pub fn rise_at(&self, age: i64) -> i64 {
        self.rise.at(age).clamp(0, FOREVER as i64)
    }

    /// Rows a chain of length `n` sends: no more than the hidden rows above the well can hold.
    pub fn chain_rows_at(&self, n: i64) -> i64 {
        self.chain_rows.at(n).clamp(0, BUF as i64)
    }

    /// Slab widths a clear of `n` panels sends.
    pub fn combo_slabs(&self, n: usize) -> &[u8] {
        if n < self.combo_from as usize {
            return &[];
        }
        let k = (n - self.combo_from as usize).min(self.combo.len() - 1);
        &self.combo[k]
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(128);
        out.extend_from_slice(MAGIC);
        out.push(LAYOUT);
        out.push(self.colors);
        out.push(self.manual_raise as u8 | (self.combos_send as u8) << 1 | (self.chains_send as u8) << 2);
        for (_, v, _, _) in self.timings() {
            out.extend_from_slice(&v.to_le_bytes());
        }
        self.rise.write(&mut out);
        self.chain_rows.write(&mut out);
        out.push(self.combo_from);
        out.push(self.combo.len() as u8);
        for slabs in &self.combo {
            out.push(slabs.len() as u8);
            out.extend_from_slice(slabs);
        }
        out
    }

    /// Reads and validates. None for anything that isn't a playable ruleset in this layout.
    pub fn decode(bytes: &[u8]) -> Option<Rules> {
        let mut r = Reader { b: bytes };
        if r.take(4)? != MAGIC || r.u8()? != LAYOUT {
            return None;
        }
        let colors = r.u8()?;
        let flags = r.u8()?;
        if flags > 7 {
            return None;
        }
        let mut t = [0i32; 20];
        for v in &mut t {
            *v = r.i32()?;
        }
        let rise = Curve::read(&mut r)?;
        let chain_rows = Curve::read(&mut r)?;
        let combo_from = r.u8()?;
        let n = r.u8()? as usize;
        let mut combo = Vec::with_capacity(n);
        for _ in 0..n {
            let k = r.u8()? as usize;
            combo.push(r.take(k)?.to_vec());
        }
        if !r.b.is_empty() {
            return None;
        }
        let rules = Rules {
            colors,
            manual_raise: flags & 1 != 0,
            combos_send: flags & 2 != 0,
            chains_send: flags & 4 != 0,
            swap: t[0],
            hover: t[1],
            fall: t[2],
            land: t[3],
            flash: t[4],
            pop: t[5],
            reveal: t[6],
            shell_pop: t[7],
            garbage_hang: t[8],
            repeat_delay: t[9],
            repeat_rate: t[10],
            time_slow: t[11],
            time_ramp: t[12],
            row_units: t[13],
            raise_speed: t[14],
            stop: t[15],
            countdown: t[16],
            health: t[17],
            garbage_delay: t[18],
            garbage_gap: t[19],
            rise,
            chain_rows,
            combo_from,
            combo,
        };
        rules.validate().ok()?;
        Some(rules)
    }

    /// Names a ruleset in one number: the hash of its bytes.
    pub fn fingerprint(&self) -> i64 {
        hash64(&self.encode())
    }
}

impl Rules {
    /// One standard ruleset for every match that doesn't ask for another.
    pub fn shared_standard() -> Arc<Rules> {
        static STANDARD: OnceLock<Arc<Rules>> = OnceLock::new();
        STANDARD.get_or_init(|| Arc::new(Rules::standard())).clone()
    }
}

impl Default for Rules {
    fn default() -> Rules {
        Rules::standard()
    }
}

struct Reader<'a> {
    b: &'a [u8],
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        if self.b.len() < n {
            return None;
        }
        let (head, rest) = self.b.split_at(n);
        self.b = rest;
        Some(head)
    }
    fn u8(&mut self) -> Option<u8> {
        Some(self.take(1)?[0])
    }
    fn bool(&mut self) -> Option<bool> {
        match self.u8()? {
            0 => Some(false),
            1 => Some(true),
            _ => None,
        }
    }
    fn i32(&mut self) -> Option<i32> {
        Some(i32::from_le_bytes(self.take(4)?.try_into().ok()?))
    }
}
