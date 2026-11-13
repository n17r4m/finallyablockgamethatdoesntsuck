//! A whole game as data: seed, starting setup, every input change, and state hashes along the
//! way. The byte layout is in `docs/engine-contract.md`. `decode` treats its input as hostile:
//! nothing in a file can make it panic, read out of bounds, or allocate more than the file's
//! size, and every file it accepts is safe to simulate.

use crate::consts::*;
use crate::rules::Rules;
use crate::state::{teams_error, State};
use sha2::{Digest, Sha256};
use std::sync::Arc;

/// The newest format, written for any match format 1 can't hold: more than two seats, other
/// teams, or rules other than the standard ones.
pub const FORMAT: u8 = 2;
pub const TRAILER: usize = 8;
pub const MAX_TICKS: u64 = TICK_HZ as u64 * 60 * 60 * 2; // two hours; a limit on verification cost

const MAGIC: &[u8; 4] = b"FBGR";
const OP_CLEAR: u8 = 0;
const OP_PUT: u8 = 1;
const OP_GARBAGE: u8 = 2;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SetupOp {
    Clear { board: u8 },
    Put { board: u8, x: u8, row: u8, color: u8 },
    Garbage { board: u8, w: u8, h: u8 },
}

/// One player's input changes: from `tick` on, the input is `mask`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct InputEvent {
    pub tick: u64,
    pub mask: u32,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Replay {
    pub rules: u16,
    pub tick_hz: u16,
    pub seed: i64,
    pub solo: bool,
    pub end_tick: u64,
    pub start_hash: i64,
    pub setup: Vec<SetupOp>,
    /// Each seat's team. `[0, 1]` for a 1v1.
    pub teams: Vec<u8>,
    /// What the match played by.
    pub ruleset: Arc<Rules>,
    /// One list per seat.
    pub inputs: Vec<Vec<InputEvent>>,
    pub checkpoints: Vec<(u64, i64)>,
}

impl Replay {
    /// Whether format 1 can hold this match: a 1v1 on the standard rules.
    pub fn fits_format_1(&self) -> bool {
        self.teams == [0, 1] && (Arc::ptr_eq(&self.ruleset, &Rules::shared_standard()) || *self.ruleset == *Rules::shared_standard())
    }

    /// The state at tick 0, before any input.
    pub fn new_state(&self) -> State {
        let mut s = State::seated(self.seed, self.solo, self.ruleset.clone(), &self.teams);
        for op in &self.setup {
            match *op {
                SetupOp::Clear { board } => s.boards[board as usize].clear_all(),
                SetupOp::Put { board, x, row, color } => {
                    s.boards[board as usize].put(x as usize, row as usize, color)
                }
                SetupOp::Garbage { board, w, h } => {
                    s.boards[board as usize].receive_garbage(&[slab(w as i32, h as i32)])
                }
            }
        }
        s
    }

    /// Re-simulates and checks every hash. Returns the final state if the game is genuine.
    pub fn verify(&self) -> Result<State, String> {
        self.verify_with(|_| {})
    }

    /// As `verify`, calling `on_tick` with the state after every tick.
    pub fn verify_with(&self, mut on_tick: impl FnMut(&State)) -> Result<State, String> {
        if self.rules != RULES_VERSION {
            return Err(format!("rules version {}, this build is {RULES_VERSION}", self.rules));
        }
        if self.tick_hz != TICK_HZ {
            return Err(format!("tick rate {}, this build is {TICK_HZ}", self.tick_hz));
        }
        let mut s = self.new_state();
        if s.checksum() != self.start_hash {
            return Err("start state differs".into());
        }
        let n = self.teams.len();
        let mut next = [0usize; MAX_SEATS];
        let mut mask = [0u32; MAX_SEATS];
        let mut next_check = 0;
        for t in 0..self.end_tick {
            for p in 0..n {
                if let Some(e) = self.inputs[p].get(next[p]) {
                    if e.tick == t {
                        mask[p] = e.mask;
                        next[p] += 1;
                    }
                }
            }
            s.step_all(&mask[..n]);
            on_tick(&s);
            if let Some(&(tick, hash)) = self.checkpoints.get(next_check) {
                if tick == s.tick as u64 {
                    if s.checksum() != hash {
                        return Err(format!("state differs at tick {tick}"));
                    }
                    next_check += 1;
                }
            }
        }
        if next_check != self.checkpoints.len() {
            return Err("checkpoints past the end".into());
        }
        Ok(s)
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        let format = if self.fits_format_1() { 1 } else { FORMAT };
        out.extend_from_slice(MAGIC);
        out.push(format);
        out.extend_from_slice(&self.rules.to_le_bytes());
        out.extend_from_slice(&self.tick_hz.to_le_bytes());
        out.push(self.solo as u8);
        out.extend_from_slice(&self.seed.to_le_bytes());
        if format == 2 {
            out.push(self.teams.len() as u8);
            out.extend_from_slice(&self.teams);
            let rules = if *self.ruleset == *Rules::shared_standard() { Vec::new() } else { self.ruleset.encode() };
            put_var(&mut out, rules.len() as u64);
            out.extend_from_slice(&rules);
        }
        put_var(&mut out, self.end_tick);
        out.extend_from_slice(&self.start_hash.to_le_bytes());
        put_var(&mut out, self.setup.len() as u64);
        for op in &self.setup {
            match *op {
                SetupOp::Clear { board } => out.extend_from_slice(&[OP_CLEAR, board]),
                SetupOp::Put { board, x, row, color } => {
                    out.extend_from_slice(&[OP_PUT, board, x, row, color])
                }
                SetupOp::Garbage { board, w, h } => {
                    out.extend_from_slice(&[OP_GARBAGE, board, w, h])
                }
            }
        }
        for events in &self.inputs {
            put_var(&mut out, events.len() as u64);
            let mut prev: i64 = -1;
            for e in events {
                put_var(&mut out, (e.tick as i64 - prev) as u64);
                put_var(&mut out, e.mask as u64);
                prev = e.tick as i64;
            }
        }
        put_var(&mut out, self.checkpoints.len() as u64);
        let mut prev = 0;
        for &(tick, hash) in &self.checkpoints {
            put_var(&mut out, tick - prev);
            out.extend_from_slice(&hash.to_le_bytes());
            prev = tick;
        }
        seal(out)
    }

    pub fn decode(bytes: &[u8]) -> Result<Replay, String> {
        if bytes.len() < 4 + 1 + 2 + 2 + 1 + 8 + TRAILER {
            return Err("too short".into());
        }
        let (body, trailer) = bytes.split_at(bytes.len() - TRAILER);
        if Sha256::digest(body)[..TRAILER] != *trailer {
            return Err("damaged: integrity trailer doesn't match".into());
        }
        let mut r = Reader { b: body, p: 0 };
        if r.take(4)? != MAGIC {
            return Err("not a replay".into());
        }
        let format = r.u8()?;
        if format != 1 && format != FORMAT {
            return Err(format!("replay format {format}, this build reads 1 to {FORMAT}"));
        }
        let rules = r.u16()?;
        let tick_hz = r.u16()?;
        let flags = r.u8()?;
        if flags > 1 {
            return Err("unknown flags".into());
        }
        let seed = r.i64()?;
        let (teams, ruleset) = if format == 1 {
            (vec![0, 1], Rules::shared_standard())
        } else {
            let n = r.u8()? as usize;
            let teams = r.take(n)?.to_vec();
            if let Some(why) = teams_error(&teams) {
                return Err(format!("bad teams: {why}"));
            }
            let len = r.count()?;
            let bytes = r.take(len)?;
            let ruleset = if bytes.is_empty() {
                Rules::shared_standard()
            } else {
                Arc::new(Rules::decode(bytes).ok_or("bad rules")?)
            };
            (teams, ruleset)
        };
        let end_tick = r.var()?;
        if end_tick > MAX_TICKS {
            return Err("too long".into());
        }
        let start_hash = r.i64()?;
        let setup = read_setup(&mut r, teams.len())?;
        let inputs = (0..teams.len()).map(|_| read_inputs(&mut r, end_tick)).collect::<Result<Vec<_>, _>>()?;
        let checkpoints = read_checks(&mut r, end_tick)?;
        if r.p != body.len() {
            return Err("trailing bytes".into());
        }
        Ok(Replay {
            rules,
            tick_hz,
            seed,
            solo: flags == 1,
            end_tick,
            start_hash,
            setup,
            teams,
            ruleset,
            inputs,
            checkpoints,
        })
    }
}

/// Appends the integrity trailer. It catches damage, not forgery: a forged replay has to
/// survive `verify`, and the referee is what makes that matter.
pub fn seal(mut body: Vec<u8>) -> Vec<u8> {
    let digest = Sha256::digest(&body);
    body.extend_from_slice(&digest[..TRAILER]);
    body
}

fn put_var(out: &mut Vec<u8>, mut v: u64) {
    while v >= 0x80 {
        out.push((v & 0x7F) as u8 | 0x80);
        v >>= 7;
    }
    out.push(v as u8);
}

fn read_setup(r: &mut Reader, seats: usize) -> Result<Vec<SetupOp>, String> {
    let n = r.count()?;
    let mut out = Vec::with_capacity(n);
    for _ in 0..n {
        let kind = r.u8()?;
        let board = r.u8()?;
        if board as usize >= seats {
            return Err("bad board in setup".into());
        }
        out.push(match kind {
            OP_CLEAR => SetupOp::Clear { board },
            OP_PUT => {
                let (x, row, color) = (r.u8()?, r.u8()?, r.u8()?);
                if x as usize >= W || row as usize >= ROWS || color > COLORS {
                    return Err("bad cell in setup".into());
                }
                SetupOp::Put { board, x, row, color }
            }
            OP_GARBAGE => {
                let (w, h) = (r.u8()?, r.u8()?);
                if w < 1 || w as usize > W || h < 1 || h as usize > BUF {
                    return Err("bad slab in setup".into());
                }
                SetupOp::Garbage { board, w, h }
            }
            _ => return Err("unknown setup op".into()),
        });
    }
    Ok(out)
}

fn read_inputs(r: &mut Reader, end_tick: u64) -> Result<Vec<InputEvent>, String> {
    let n = r.count()?;
    let mut out = Vec::with_capacity(n);
    let mut next = 0; // the lowest tick the next event can have
    for _ in 0..n {
        let delta = r.var()?;
        let mask = r.var()?;
        if delta < 1 {
            return Err("input ticks must ascend".into());
        }
        let tick = next + delta - 1;
        if tick >= end_tick {
            return Err("input past the end".into());
        }
        if mask & !(INPUT_BITS as u64) != 0 {
            return Err("unknown input bits".into());
        }
        out.push(InputEvent { tick, mask: mask as u32 });
        next = tick + 1;
    }
    Ok(out)
}

fn read_checks(r: &mut Reader, end_tick: u64) -> Result<Vec<(u64, i64)>, String> {
    let n = r.count()?;
    let mut out = Vec::with_capacity(n);
    let mut prev = 0;
    for _ in 0..n {
        let delta = r.var()?;
        let hash = r.i64()?;
        if delta < 1 {
            return Err("checkpoints must ascend".into());
        }
        prev += delta;
        if prev > end_tick {
            return Err("checkpoint past the end".into());
        }
        out.push((prev, hash));
    }
    if out.is_empty() {
        return Err("no checkpoints".into());
    }
    if prev != end_tick {
        return Err("last checkpoint isn't the end".into());
    }
    Ok(out)
}

struct Reader<'a> {
    b: &'a [u8],
    p: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], String> {
        if n > self.b.len() - self.p {
            return Err("truncated".into());
        }
        let out = &self.b[self.p..self.p + n];
        self.p += n;
        Ok(out)
    }

    fn u8(&mut self) -> Result<u8, String> {
        Ok(self.take(1)?[0])
    }

    fn u16(&mut self) -> Result<u16, String> {
        let b = self.take(2)?;
        Ok(u16::from_le_bytes([b[0], b[1]]))
    }

    fn i64(&mut self) -> Result<i64, String> {
        let mut out = [0; 8];
        out.copy_from_slice(self.take(8)?);
        Ok(i64::from_le_bytes(out))
    }

    /// An element count. Every element takes at least a byte, so more than what's left is a lie.
    fn count(&mut self) -> Result<usize, String> {
        let n = self.var()?;
        if n > (self.b.len() - self.p) as u64 {
            return Err("count larger than the file".into());
        }
        Ok(n as usize)
    }

    /// An unsigned LEB128 varint of at most 8 bytes.
    fn var(&mut self) -> Result<u64, String> {
        let mut v = 0;
        let mut shift = 0;
        loop {
            let byte = self.u8()?;
            if shift > 55 || (byte == 0 && shift > 0) {
                return Err("bad varint".into());
            }
            v |= ((byte & 0x7F) as u64) << shift;
            if byte < 0x80 {
                return Ok(v);
            }
            shift += 7;
        }
    }
}
