//! The entire deterministic game: both wells, the tick counter and the result.

use crate::board::Board;
use crate::consts::COUNTDOWN_TICKS;

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct State {
    pub tick: i64,
    pub solo: bool,
    pub winner: i64, // -1 playing, 0/1 that board won, 2 draw
    pub boards: [Board; 2],
}

impl State {
    pub fn new(seed: i64, solo: bool) -> State {
        // Same seed for both wells so the start is fair.
        State { tick: 0, solo, winner: -1, boards: [Board::new(seed), Board::new(seed)] }
    }

    pub fn step(&mut self, input0: u32, input1: u32) {
        if self.winner == -1 {
            let live = self.tick >= COUNTDOWN_TICKS;
            self.boards[0].step(input0, live);
            if !self.solo {
                self.boards[1].step(input1, live);
            }
            let [a, b] = &mut self.boards;
            if !self.solo {
                b.receive_garbage(&a.outbox);
            }
            a.outbox.clear();
            if !self.solo {
                a.receive_garbage(&b.outbox);
            }
            b.outbox.clear();
            let (l0, l1) = (a.lost, b.lost);
            if l0 || l1 {
                self.winner = if l0 && l1 { 2 } else if l0 { 1 } else { 0 };
            }
        }
        self.tick += 1;
    }

    pub fn checksum(&self) -> i64 {
        crate::hash64(&self.canonical_bytes())
    }

    /// The exact bytes the state hash covers: tick i64, solo u8, winner i64, then each board.
    pub fn canonical_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(5200);
        out.extend_from_slice(&self.tick.to_le_bytes());
        out.push(self.solo as u8);
        out.extend_from_slice(&self.winner.to_le_bytes());
        self.boards[0].write_canonical(&mut out);
        self.boards[1].write_canonical(&mut out);
        out
    }
}
