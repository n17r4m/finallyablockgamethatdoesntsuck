//! Plays a match alongside its players, on the real rules, from the inputs they send.
//!
//! It runs up to the tick both players have made final, so it never predicts or rolls back.
//! When a player's reported hash differs from its own, that player is wrong: unlike two peers
//! comparing notes, this can say which. All time comes in as a parameter, so everything here
//! can be tested without a clock or a socket.

use crate::protocol::{EndReason, InputMsg};
use fbg_sim::consts::{INPUT_BITS, RULES_VERSION, TICK_HZ};
use fbg_sim::replay::{InputEvent, MAX_TICKS};
use fbg_sim::{Replay, State};
use std::collections::BTreeMap;

const HZ: i64 = TICK_HZ as i64;
/// A frontier this far past the server's clock can't come from a player who started with it.
pub const MAX_FUTURE: i64 = HZ * 2;
/// A player whose inputs stop for this long, while holding the match up, forfeits.
pub const STALL_LIMIT: i64 = HZ * 10;
const MAX_PENDING_CHECKS: usize = 64;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Outcome {
    pub winner: u8, // 0 or 1, or 2 for a draw
    pub reason: EndReason,
    pub tick: i64,
}

pub struct Referee {
    seed: i64,
    start_hash: i64,
    state: State,
    inputs: [Vec<InputEvent>; 2],
    next: [usize; 2],
    masks: [u32; 2],
    frontier: [i64; 2],
    last_change: [i64; 2],
    last_advance: [i64; 2],
    reported: [BTreeMap<i64, i64>; 2],
    checked: [i64; 2],
    own_checks: Vec<(u64, i64)>,
    outcome: Option<Outcome>,
    /// Most ticks behind the server's clock any accepted input arrived, per player.
    pub latest_input: [i64; 2],
}

impl Referee {
    pub fn new(seed: i64) -> Referee {
        let state = State::new(seed, false);
        Referee {
            seed,
            start_hash: state.checksum(),
            state,
            inputs: [Vec::new(), Vec::new()],
            next: [0, 0],
            masks: [0, 0],
            frontier: [-1, -1],
            last_change: [-1, -1],
            last_advance: [0, 0],
            reported: [BTreeMap::new(), BTreeMap::new()],
            checked: [0, 0],
            own_checks: Vec::new(),
            outcome: None,
            latest_input: [0, 0],
        }
    }

    pub fn outcome(&self) -> Option<Outcome> {
        self.outcome
    }

    pub fn tick(&self) -> i64 {
        self.state.tick
    }

    /// Ends the match against `seat`.
    pub fn forfeit(&mut self, seat: usize, reason: EndReason) {
        if self.outcome.is_none() {
            self.outcome = Some(Outcome { winner: 1 - seat as u8, reason, tick: self.state.tick });
        }
    }

    /// Takes one player's message, at `now` ticks on the server's clock. Applies the same
    /// acceptance rule as RollbackSession.receive, so both ends of the relay agree on what
    /// counted. Returns false if the message broke the rules and the match has ended over it.
    pub fn input(&mut self, seat: usize, m: &InputMsg, now: i64) -> bool {
        if self.outcome.is_some() {
            return true; // a player can't know yet, and it no longer matters
        }
        if m.frontier > now + MAX_FUTURE {
            self.forfeit(seat, EndReason::BadInput);
            return false;
        }
        for &(t, mask) in &m.changes {
            if t > m.frontier || mask as u32 & !INPUT_BITS != 0 {
                self.forfeit(seat, EndReason::BadInput);
                return false;
            }
            if t <= self.last_change[seat] || t <= self.frontier[seat] {
                continue; // a resend
            }
            self.inputs[seat].push(InputEvent { tick: t as u64, mask: mask as u32 });
            self.last_change[seat] = t;
            self.latest_input[seat] = self.latest_input[seat].max(now - t);
        }
        if m.frontier > self.frontier[seat] {
            self.frontier[seat] = m.frontier;
            self.last_advance[seat] = now;
        }
        for &(k, hash) in &m.checks {
            if k <= self.checked[seat] {
                continue;
            }
            if k % HZ != 0 || k > m.tick {
                self.forfeit(seat, EndReason::BadInput);
                return false;
            }
            self.reported[seat].insert(k, hash);
            if self.reported[seat].len() > MAX_PENDING_CHECKS {
                self.forfeit(seat, EndReason::BadInput);
                return false;
            }
        }
        self.advance();
        self.compare();
        self.outcome.is_none_or(|o| o.reason != EndReason::WrongState)
    }

    /// Call now and then: the clock alone can end a match.
    pub fn check_clock(&mut self, now: i64) {
        if self.outcome.is_some() {
            return;
        }
        // The stuck player is whoever is furthest behind: the other runs out of room to
        // predict soon after, and then stops too, through no fault of its own.
        let seat = if self.frontier[0] <= self.frontier[1] { 0 } else { 1 };
        if now - self.last_advance[seat] > STALL_LIMIT {
            self.forfeit(seat, EndReason::Stalled);
        }
    }

    fn advance(&mut self) {
        let limit = self.frontier[0].min(self.frontier[1]);
        while self.state.tick <= limit && self.state.winner == -1 && self.outcome.is_none() {
            let t = self.state.tick as u64;
            for p in 0..2 {
                while let Some(e) = self.inputs[p].get(self.next[p]).filter(|e| e.tick <= t) {
                    self.masks[p] = e.mask;
                    self.next[p] += 1;
                }
            }
            self.state.step(self.masks[0], self.masks[1]);
            if self.state.tick % HZ == 0 {
                self.own_checks.push((self.state.tick as u64, self.state.checksum()));
            }
            if self.state.tick >= MAX_TICKS as i64 {
                self.outcome = Some(Outcome { winner: 2, reason: EndReason::TooLong, tick: self.state.tick });
            }
        }
    }

    /// Hashes reported for ticks we've reached. A player who's wrong forfeits. If both are
    /// wrong at the same point, it isn't either player's game any more: a draw.
    fn compare(&mut self) {
        let reached = self.state.tick;
        let mut wrong = [false, false];
        for p in 0..2 {
            let due: Vec<i64> = self.reported[p].range(..=reached).map(|(k, _)| *k).collect();
            for k in due {
                let told = self.reported[p].remove(&k);
                let own = self.own_checks.binary_search_by_key(&(k as u64), |c| c.0).ok().map(|i| self.own_checks[i].1);
                self.checked[p] = self.checked[p].max(k);
                if own.is_some() && own != told {
                    wrong[p] = true;
                }
            }
        }
        if self.outcome.is_some() {
            return;
        }
        match wrong {
            [true, true] => self.outcome = Some(Outcome { winner: 2, reason: EndReason::WrongState, tick: reached }),
            [true, false] => self.forfeit(0, EndReason::WrongState),
            [false, true] => self.forfeit(1, EndReason::WrongState),
            _ => {
                if self.state.winner != -1 {
                    self.outcome = Some(Outcome { winner: self.state.winner as u8, reason: EndReason::Played, tick: reached });
                }
            }
        }
    }

    /// The match as a replay anyone can check, up to the last point the referee hashed. None
    /// if it ended before the first hash.
    pub fn replay(&self) -> Option<Replay> {
        let mut checkpoints = self.own_checks.clone();
        if self.state.winner != -1 && checkpoints.last().map(|c| c.0) != Some(self.state.tick as u64) {
            checkpoints.push((self.state.tick as u64, self.state.checksum()));
        }
        let end_tick = checkpoints.last()?.0;
        let upto = |p: usize| self.inputs[p].iter().copied().filter(|e| e.tick < end_tick).collect::<Vec<_>>();
        Some(Replay {
            rules: RULES_VERSION,
            tick_hz: TICK_HZ,
            seed: self.seed,
            solo: false,
            end_tick,
            start_hash: self.start_hash,
            setup: Vec::new(),
            inputs: [upto(0), upto(1)],
            checkpoints,
        })
    }
}
