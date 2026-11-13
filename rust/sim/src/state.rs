//! The entire deterministic game: every seat's well, the tick counter and the result.
//!
//! A match seats any number of players, each with a well, on two or more teams. Garbage a
//! board sends goes to one board on another team that was still playing when the tick began,
//! taking turns round the table. A board that tops out stops; a team is out when all its boards
//! are, and the last team standing wins. 1v1 is the two-seat case and plays exactly as before.

use crate::board::Board;
use crate::consts::MAX_SEATS;
use crate::rules::Rules;
use std::sync::Arc;

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct State {
    pub tick: i64,
    pub solo: bool,
    /// -1 while playing, then the winning team, or the team count for a draw (2 in a 1v1).
    pub winner: i64,
    pub boards: Vec<Board>,
    /// The match's rules: the countdown, and what each board starts with. Not hashed.
    pub rules: Arc<Rules>,
    /// Each seat's team, numbered from 0 with none left out. Never changes, not hashed.
    pub teams: Arc<[u8]>,
    pub team_count: u8,
    /// Per board, the seat its next garbage tries first. Hashed when there are more than two
    /// boards, the only time it can matter.
    pub aim: Vec<u8>,
}

/// Why these can't be a match's teams, or None if they can: two to MAX_SEATS seats, teams
/// numbered from 0 with none empty, and at least two of them.
pub fn teams_error(teams: &[u8]) -> Option<String> {
    if teams.len() < 2 || teams.len() > MAX_SEATS {
        return Some(format!("{} seats; a match has 2 to {MAX_SEATS}", teams.len()));
    }
    let count = teams.iter().map(|&t| t as usize + 1).max().unwrap_or(0);
    if count > teams.len() {
        return Some(format!("team {}", count - 1));
    }
    if count < 2 {
        return Some("one team".into());
    }
    (0..count).find(|t| !teams.contains(&(*t as u8))).map(|t| format!("no seat on team {t}"))
}

impl State {
    /// A match on the standard rules.
    pub fn new(seed: i64, solo: bool) -> State {
        State::with_rules(seed, solo, Rules::shared_standard())
    }

    /// A 1v1 on these rules, which must be valid (`Rules::decode` and `validate` see to it).
    pub fn with_rules(seed: i64, solo: bool, rules: Arc<Rules>) -> State {
        State::seated(seed, solo, rules, &[0, 1])
    }

    /// A match on these rules and teams, which must be valid (see `teams_error`).
    pub fn seated(seed: i64, solo: bool, rules: Arc<Rules>, teams: &[u8]) -> State {
        assert!(teams_error(teams).is_none(), "{teams:?}");
        let n = teams.len();
        // Same seed for every well so the start is fair.
        let boards = (0..n).map(|_| Board::new(seed, rules.clone())).collect();
        let team_count = teams.iter().max().map_or(0, |t| t + 1);
        let aim = (0..n).map(|p| ((p + 1) % n) as u8).collect();
        State { tick: 0, solo, winner: -1, boards, rules, teams: teams.into(), team_count, aim }
    }

    /// A 1v1's step: both seats' inputs.
    pub fn step(&mut self, input0: u32, input1: u32) {
        self.step_all(&[input0, input1]);
    }

    /// One tick, with an input for every seat.
    pub fn step_all(&mut self, inputs: &[u32]) {
        if self.winner == -1 {
            let live = self.tick >= self.rules.countdown as i64;
            if self.solo {
                self.boards[0].step(inputs[0], live);
                self.boards[0].outbox.clear();
            } else {
                let n = self.boards.len();
                let mut playing = [false; MAX_SEATS];
                for p in 0..n {
                    playing[p] = !self.boards[p].lost;
                    self.boards[p].step(inputs[p], live);
                }
                for p in 0..n {
                    if self.boards[p].outbox.is_empty() {
                        continue;
                    }
                    let out = std::mem::take(&mut self.boards[p].outbox);
                    if let Some(to) = self.target(p, &playing) {
                        self.boards[to].receive_garbage(&out);
                    }
                    self.boards[p].outbox = out;
                    self.boards[p].outbox.clear();
                }
            }
            self.judge();
        }
        self.tick += 1;
    }

    /// Who board p's garbage goes to: the first board on another team, from p's aim round the
    /// table, that was playing when the tick began.
    fn target(&mut self, p: usize, playing: &[bool]) -> Option<usize> {
        let n = self.boards.len();
        let to = (0..n).map(|k| (self.aim[p] as usize + k) % n).find(|&q| self.teams[q] != self.teams[p] && playing[q])?;
        self.aim[p] = ((to + 1) % n) as u8;
        Some(to)
    }

    /// The match ends when at most one team has a board still playing. In practice board 1
    /// never plays, so it stands until board 0 falls.
    fn judge(&mut self) {
        let mut seen = 0u64;
        let mut standing = -1i64;
        for (b, &t) in self.boards.iter().zip(self.teams.iter()) {
            if !b.lost {
                seen |= 1 << t;
                standing = t as i64;
            }
        }
        match seen.count_ones() {
            0 => self.winner = self.team_count as i64,
            1 => self.winner = standing,
            _ => {}
        }
    }

    /// Whether board p's team won.
    pub fn won(&self, p: usize) -> bool {
        self.winner >= 0 && self.winner != self.team_count as i64 && self.teams[p] as i64 == self.winner
    }

    pub fn checksum(&self) -> i64 {
        crate::hash64(&self.canonical_bytes())
    }

    /// The exact bytes the state hash covers: tick i64, solo u8, winner i64, then each board,
    /// then with more than two boards each one's aim as i64.
    pub fn canonical_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(2600 * self.boards.len());
        out.extend_from_slice(&self.tick.to_le_bytes());
        out.push(self.solo as u8);
        out.extend_from_slice(&self.winner.to_le_bytes());
        for b in &self.boards {
            b.write_canonical(&mut out);
        }
        if self.boards.len() > 2 {
            for &a in &self.aim {
                out.extend_from_slice(&(a as i64).to_le_bytes());
            }
        }
        out
    }
}
