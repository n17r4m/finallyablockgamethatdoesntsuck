//! Plays a match alongside its players, on the real rules, from the inputs they send.
//!
//! It runs up to the tick both players have made final, so it never predicts or rolls back.
//! When a player's reported hash differs from its own, that player is wrong: unlike two peers
//! comparing notes, this can say which. All time comes in as a parameter, so everything here
//! can be tested without a clock or a socket.

use crate::protocol::{EndReason, InputMsg};
use fbg_sim::consts::{INPUT_BITS, MAX_SEATS, RULES_VERSION, TICK_HZ};
use fbg_sim::replay::{InputEvent, MAX_TICKS};
use fbg_sim::{Replay, Rules, State};
use std::sync::Arc;
use std::collections::BTreeMap;

const HZ: i64 = TICK_HZ as i64;
/// A frontier this far past the server's clock can't come from a player who started with it.
pub const MAX_FUTURE: i64 = HZ * 2;
/// A player whose inputs stop for this long, while holding the match up, forfeits.
pub const STALL_LIMIT: i64 = HZ * 10;
const MAX_PENDING_CHECKS: usize = 64;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Outcome {
    /// The winning team, or the team count for a draw (2 in a 1v1).
    pub winner: u8,
    pub reason: EndReason,
    pub tick: i64,
}

/// Everything here is per seat.
pub struct Referee {
    seed: i64,
    start_hash: i64,
    state: State,
    inputs: Vec<Vec<InputEvent>>,
    next: Vec<usize>,
    masks: [u32; MAX_SEATS],
    frontier: Vec<i64>,
    last_change: Vec<i64>,
    last_advance: Vec<i64>,
    reported: Vec<BTreeMap<i64, i64>>,
    checked: Vec<i64>,
    own_checks: Vec<(u64, i64)>,
    outcome: Option<Outcome>,
    /// Most ticks behind the server's clock any accepted input arrived, per player.
    pub latest_input: Vec<i64>,
}

impl Referee {
    /// A match on the standard rules.
    pub fn new(seed: i64) -> Referee {
        Referee::with_rules(seed, Rules::shared_standard())
    }

    /// A 1v1 on these rules, which must be valid.
    pub fn with_rules(seed: i64, rules: Arc<Rules>) -> Referee {
        Referee::seated(seed, rules, &[0, 1])
    }

    /// A match on these rules and teams, which must be valid.
    pub fn seated(seed: i64, rules: Arc<Rules>, teams: &[u8]) -> Referee {
        let state = State::seated(seed, false, rules, teams);
        let n = teams.len();
        Referee {
            seed,
            start_hash: state.checksum(),
            state,
            inputs: vec![Vec::new(); n],
            next: vec![0; n],
            masks: [0; MAX_SEATS],
            frontier: vec![-1; n],
            last_change: vec![-1; n],
            last_advance: vec![0; n],
            reported: vec![BTreeMap::new(); n],
            checked: vec![0; n],
            own_checks: Vec::new(),
            outcome: None,
            latest_input: vec![0; n],
        }
    }

    pub fn seats(&self) -> usize {
        self.frontier.len()
    }

    /// The team a seat plays for.
    pub fn team(&self, seat: usize) -> u8 {
        self.state.teams[seat]
    }

    pub fn outcome(&self) -> Option<Outcome> {
        self.outcome
    }

    pub fn tick(&self) -> i64 {
        self.state.tick
    }

    /// The game as far as the referee has played it.
    pub fn state(&self) -> &State {
        &self.state
    }

    /// The tick up to which each player's inputs are final.
    pub fn frontiers(&self) -> &[i64] {
        &self.frontier
    }

    /// Ends the match as a draw, on the say-so of whoever runs the server.
    pub fn end(&mut self) {
        if self.outcome.is_none() {
            self.outcome = Some(Outcome { winner: self.state.team_count, reason: EndReason::Ended, tick: self.state.tick });
        }
    }

    /// Ends the match against `seat`'s team. With two teams the other wins; with more, nobody
    /// can say who would have, so it's a draw among the rest.
    pub fn forfeit(&mut self, seat: usize, reason: EndReason) {
        if self.outcome.is_none() {
            let count = self.state.team_count;
            let winner = if count == 2 { 1 - self.team(seat) } else { count };
            self.outcome = Some(Outcome { winner, reason, tick: self.state.tick });
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
        // The stuck player is whoever is furthest behind: the others run out of room to
        // predict soon after, and then stop too, through no fault of their own.
        let seat = (0..self.seats()).min_by_key(|&p| self.frontier[p]).unwrap_or(0);
        if now - self.last_advance[seat] > STALL_LIMIT {
            self.forfeit(seat, EndReason::Stalled);
        }
    }

    fn advance(&mut self) {
        let n = self.seats();
        let limit = self.frontier.iter().copied().min().unwrap_or(-1);
        while self.state.tick <= limit && self.state.winner == -1 && self.outcome.is_none() {
            let t = self.state.tick as u64;
            for p in 0..n {
                while let Some(e) = self.inputs[p].get(self.next[p]).filter(|e| e.tick <= t) {
                    self.masks[p] = e.mask;
                    self.next[p] += 1;
                }
            }
            self.state.step_all(&self.masks[..n]);
            if self.state.tick % HZ == 0 {
                self.own_checks.push((self.state.tick as u64, self.state.checksum()));
            }
            if self.state.tick >= MAX_TICKS as i64 {
                self.outcome = Some(Outcome { winner: 2, reason: EndReason::TooLong, tick: self.state.tick });
            }
        }
    }

    /// Hashes reported for ticks we've reached. A player who's wrong forfeits. If more than
    /// one is wrong at the same point, it isn't anyone's game any more: a draw.
    fn compare(&mut self) {
        let reached = self.state.tick;
        let mut wrong = [false; MAX_SEATS];
        for p in 0..self.seats() {
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
        let liars: Vec<usize> = (0..self.seats()).filter(|&p| wrong[p]).collect();
        match liars[..] {
            [] => {
                if self.state.winner != -1 {
                    self.outcome = Some(Outcome { winner: self.state.winner as u8, reason: EndReason::Played, tick: reached });
                }
            }
            [p] => self.forfeit(p, EndReason::WrongState),
            _ => self.outcome = Some(Outcome { winner: self.state.team_count, reason: EndReason::WrongState, tick: reached }),
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
            teams: self.state.teams.to_vec(),
            ruleset: self.state.rules.clone(),
            inputs: (0..self.seats()).map(upto).collect(),
            checkpoints,
        })
    }
}
