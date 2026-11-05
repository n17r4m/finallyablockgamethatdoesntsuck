//! One player's well: Panel de Pon rules on an integer grid. Every cell runs a small state
//! machine driven by tick timers. This follows `sim/sim_board.gd` function by function, in the
//! same order, because the order things happen in is part of the rules.

use crate::consts::*;

pub const NORMAL: u8 = 0;
pub const SWAP_L: u8 = 1;
pub const SWAP_R: u8 = 2;
pub const HOVER: u8 = 3;
pub const FALL: u8 = 4;
pub const LAND: u8 = 5;
pub const MATCHED: u8 = 6;

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Board {
    // Per cell, row-major, y = 0 is the top of the hidden buffer.
    pub color: [u8; N], // 0 empty, 1..COLORS panel, GARBAGE
    pub st: [u8; N],
    pub tm: [i32; N],   // ticks left in the current state
    pub aux: [i32; N],  // MATCHED: pop tick | flash-end tick << 16
    pub chain: [u8; N], // 1 = falling because something under it cleared
    pub gid: [i32; N],  // garbage slab id, 0 = panel
    pub reveal: [u8; N], // cracking garbage: the panel colour this cell becomes
    pub next_row: [u8; W], // rising in from below

    pub cursor_x: i64, // cursor covers cursor_x and cursor_x + 1
    pub cursor_y: i64,
    pub prev_input: u32,
    pub hold: i64,
    pub rise: i64,
    pub stop_t: i64,
    pub health: i64, // drains while topped out; 0 = lost
    pub rng: u32,
    pub score: i64,
    pub lost: bool,

    pub busy: bool,         // some cell is not NORMAL; run the per-cell update
    pub need_scan: bool,    // a panel came to rest; look for matches
    pub need_support: bool, // a cell emptied; look for unsupported blocks
    pub has_matched: bool,
    pub chain_n: i64, // current chain length; 1 = no chain

    pub outbox: Vec<i32>, // slabs sent this tick; State delivers them
    pub gar_q: Vec<i32>,  // incoming slabs, head drops first
    pub gar_t: i64,
    pub gar_side: i64, // alternate narrow slabs left/right
    pub next_gid: i64,

    pub fx_combo: i64, // latest callouts for presentation
    pub fx_chain: i64,
    pub fx_t: i64,

    pub age: i64, // live ticks; drives the rise speed-up
    pub sent: i64,
    pub best_chain: i64,
    pub swaps: i64,

    pub time_rate: i64, // world clock speed in 1/TIME_UNIT steps
    pub world_acc: i64,
    pub ramp_t: i64,
    pub cracking: bool,
    pub crack_hang: i64, // world ticks left of revealed panels hanging after a crack
}

/// A slab's rectangle.
#[derive(Clone, Copy)]
struct Rect {
    x0: usize,
    y0: usize,
    w: usize,
    h: usize,
}

/// Slab ids seen this pass. A board holds at most N slabs, so this never allocates.
struct Seen {
    ids: [i32; N],
    n: usize,
}

impl Seen {
    fn new() -> Seen {
        Seen { ids: [0; N], n: 0 }
    }

    fn has(&self, id: i32) -> bool {
        self.ids[..self.n].contains(&id)
    }

    fn add(&mut self, id: i32) {
        self.ids[self.n] = id;
        self.n += 1;
    }
}

/// The cells next to i: above, below, left, right. The order decides who cracks first.
fn neighbours(i: usize) -> ([usize; 4], usize) {
    let mut out = [0; 4];
    let mut n = 0;
    let x = i % W;
    if i >= W {
        out[n] = i - W;
        n += 1;
    }
    if i + W < N {
        out[n] = i + W;
        n += 1;
    }
    if x > 0 {
        out[n] = i - 1;
        n += 1;
    }
    if x < W - 1 {
        out[n] = i + 1;
        n += 1;
    }
    (out, n)
}

impl Board {
    pub fn new(seed: i64) -> Board {
        let mut b = Board {
            color: [0; N],
            st: [0; N],
            tm: [0; N],
            aux: [0; N],
            chain: [0; N],
            gid: [0; N],
            reveal: [0; N],
            next_row: [0; W],
            cursor_x: 2,
            cursor_y: TOP as i64 + 6,
            prev_input: 0,
            hold: 0,
            rise: 0,
            stop_t: 0,
            health: HEALTH_TICKS,
            rng: (seed as u64 & 0xFFFF_FFFF) as u32 | 1,
            score: 0,
            lost: false,
            busy: false,
            need_scan: false,
            need_support: false,
            has_matched: false,
            chain_n: 1,
            outbox: Vec::new(),
            gar_q: Vec::new(),
            gar_t: 0,
            gar_side: 0,
            next_gid: 1,
            fx_combo: 0,
            fx_chain: 0,
            fx_t: 0,
            age: 0,
            sent: 0,
            best_chain: 1,
            swaps: 0,
            time_rate: TIME_UNIT,
            world_acc: 0,
            ramp_t: 0,
            cracking: false,
            crack_hang: 0,
        };
        for y in ROWS - 5..ROWS {
            let row = b.make_row(y - 1);
            b.color[y * W..y * W + W].copy_from_slice(&row);
        }
        b.next_row = b.make_row(ROWS - 1);
        b
    }

    /// The exact bytes the state hash covers, in the order of the contract's field table.
    pub fn write_canonical(&self, out: &mut Vec<u8>) {
        fn bytes(out: &mut Vec<u8>, v: &[u8]) {
            out.extend_from_slice(&(v.len() as u32).to_le_bytes());
            out.extend_from_slice(v);
        }
        fn i32s(out: &mut Vec<u8>, v: &[i32]) {
            out.extend_from_slice(&(v.len() as u32).to_le_bytes());
            for x in v {
                out.extend_from_slice(&x.to_le_bytes());
            }
        }
        fn int(out: &mut Vec<u8>, v: i64) {
            out.extend_from_slice(&v.to_le_bytes());
        }
        bytes(out, &self.color);
        bytes(out, &self.st);
        i32s(out, &self.tm);
        i32s(out, &self.aux);
        bytes(out, &self.chain);
        i32s(out, &self.gid);
        bytes(out, &self.reveal);
        bytes(out, &self.next_row);
        int(out, self.cursor_x);
        int(out, self.cursor_y);
        int(out, self.prev_input as i64);
        int(out, self.hold);
        int(out, self.rise);
        int(out, self.stop_t);
        int(out, self.health);
        int(out, self.rng as i64);
        int(out, self.score);
        out.push(self.lost as u8);
        out.push(self.busy as u8);
        out.push(self.need_scan as u8);
        out.push(self.need_support as u8);
        out.push(self.has_matched as u8);
        int(out, self.chain_n);
        i32s(out, &self.outbox);
        i32s(out, &self.gar_q);
        int(out, self.gar_t);
        int(out, self.gar_side);
        int(out, self.next_gid);
        int(out, self.fx_combo);
        int(out, self.fx_chain);
        int(out, self.fx_t);
        int(out, self.age);
        int(out, self.sent);
        int(out, self.best_chain);
        int(out, self.swaps);
        int(out, self.time_rate);
        int(out, self.world_acc);
        int(out, self.ramp_t);
        out.push(self.cracking as u8);
        int(out, self.crack_hang);
    }

    /// live = false during the countdown: the cursor moves, nothing else happens.
    pub fn step(&mut self, input: u32, live: bool) {
        if self.lost {
            return;
        }
        if !live {
            self.handle_input(input & (DIRS | TARGET_MASK));
            return;
        }
        self.age += 1;
        self.handle_input(input); // player clock: every tick
        self.ease_time();
        self.world_acc += self.time_rate;
        let world = self.world_acc >= TIME_UNIT; // world clock: fewer ticks in bullet time
        if world {
            self.world_acc -= TIME_UNIT;
        }
        if self.busy {
            self.update_cells(world);
        } else {
            self.has_matched = false;
            self.cracking = false;
        }
        if self.need_support {
            self.apply_support();
        }
        if self.need_scan {
            self.scan();
        }
        if self.chain_n > 1 {
            self.check_chain_end();
        }
        if world {
            if self.crack_hang > 0 {
                self.crack_hang -= 1;
            }
            self.feed_garbage();
            self.rise_stack(input);
            if self.fx_t > 0 {
                self.fx_t -= 1;
            }
        }
    }

    /// Ease the world clock toward bullet time while garbage cracks, and back after.
    fn ease_time(&mut self) {
        let target = if self.cracking || self.crack_hang > 0 { TIME_SLOW } else { TIME_UNIT };
        if self.time_rate == target {
            self.ramp_t = 0;
            return;
        }
        self.ramp_t += 1;
        if self.ramp_t >= TIME_RAMP {
            self.ramp_t = 0;
            self.time_rate += if target > self.time_rate { 1 } else { -1 };
        }
    }

    pub fn receive_garbage(&mut self, slabs: &[i32]) {
        if slabs.is_empty() {
            return;
        }
        if self.gar_q.is_empty() {
            self.gar_t = GARBAGE_DELAY;
        }
        self.gar_q.extend_from_slice(slabs);
    }

    /// Place a resting panel; row 0 is the bottom visible row. Panics if off the board.
    pub fn put(&mut self, x: usize, row: usize, c: u8) {
        let i = (ROWS - 1 - row) * W + x;
        self.clear_cell(i);
        self.color[i] = c;
        self.need_scan = true;
        self.need_support = true;
    }

    pub fn clear_all(&mut self) {
        for i in 0..N {
            self.clear_cell(i);
        }
    }

    // --- input ------------------------------------------------------------------

    fn handle_input(&mut self, input: u32) {
        if input & TARGET != 0 {
            self.cursor_x = (((input >> 8) & 0x7) as i64).clamp(0, W as i64 - 2);
            self.cursor_y = TOP as i64 + (((input >> 12) & 0xF) as i64).clamp(0, H as i64 - 1);
        }
        let pressed = input & !self.prev_input;
        let dir = input & DIRS;
        if dir != 0 && dir == self.prev_input & DIRS {
            self.hold += 1;
            if self.hold >= REPEAT_DELAY && (self.hold - REPEAT_DELAY) % REPEAT_RATE == 0 {
                self.move_cursor(dir);
            }
        } else {
            self.hold = 0;
            if dir != 0 {
                self.move_cursor(dir);
            }
        }
        self.prev_input = input;
        if pressed & SWAP != 0 {
            self.try_swap();
        }
    }

    fn move_cursor(&mut self, dir: u32) {
        if dir & UP != 0 {
            self.cursor_y = (self.cursor_y - 1).max(TOP as i64);
        }
        if dir & DOWN != 0 {
            self.cursor_y = (self.cursor_y + 1).min(ROWS as i64 - 1);
        }
        if dir & LEFT != 0 {
            self.cursor_x = (self.cursor_x - 1).max(0);
        }
        if dir & RIGHT != 0 {
            self.cursor_x = (self.cursor_x + 1).min(W as i64 - 2);
        }
    }

    fn try_swap(&mut self) {
        let i = self.cursor_y as usize * W + self.cursor_x as usize;
        let j = i + 1;
        if self.color[i] == 0 && self.color[j] == 0 {
            return;
        }
        for k in [i, j] {
            if self.color[k] != 0 && (self.gid[k] != 0 || !self.resting(k)) {
                return;
            }
            // Don't slide into a gap something is about to fall into.
            if self.color[k] == 0
                && k >= W
                && self.color[k - W] != 0
                && (self.st[k - W] == HOVER || self.st[k - W] == FALL)
            {
                return;
            }
        }
        self.color.swap(i, j);
        self.swaps += 1;
        for k in [i, j] {
            self.st[k] = NORMAL;
            self.tm[k] = 0;
            self.chain[k] = 0;
        }
        if self.color[j] != 0 {
            self.set_state(j, SWAP_R, SWAP_TICKS); // arrived from the left
        }
        if self.color[i] != 0 {
            self.set_state(i, SWAP_L, SWAP_TICKS); // arrived from the right
        }
    }

    // --- per-cell update --------------------------------------------------------

    /// world = false on bullet-time ticks where only the player's clock runs: swaps
    /// animate, everything else holds still.
    fn update_cells(&mut self, world: bool) {
        self.busy = false;
        self.has_matched = false;
        self.cracking = false;
        let mut done = Seen::new(); // slabs already handled this tick
        for y in (0..ROWS).rev() {
            // bottom-up so columns move together
            for x in 0..W {
                let i = y * W + x;
                if self.color[i] == 0 || self.st[i] == NORMAL {
                    continue;
                }
                self.busy = true;
                if self.gid[i] != 0 {
                    if self.st[i] == MATCHED {
                        self.cracking = true;
                        self.has_matched = true;
                    }
                    if world && !done.has(self.gid[i]) {
                        done.add(self.gid[i]);
                        self.update_slab(i); // first hit is the slab's bottom-left cell
                    }
                    continue;
                }
                if !world && self.st[i] != SWAP_L && self.st[i] != SWAP_R {
                    self.has_matched = self.has_matched || self.st[i] == MATCHED;
                    continue;
                }
                match self.st[i] {
                    SWAP_L | SWAP_R => {
                        self.tm[i] -= 1;
                        if self.tm[i] == 0 {
                            self.st[i] = NORMAL;
                            self.need_scan = true;
                            self.need_support = true;
                        }
                    }
                    LAND => {
                        self.tm[i] -= 1;
                        if self.tm[i] == 0 {
                            self.st[i] = NORMAL;
                        }
                    }
                    HOVER => {
                        self.tm[i] -= 1;
                        if self.tm[i] == 0 {
                            self.st[i] = FALL;
                            self.tm[i] = FALL_TICKS;
                        }
                    }
                    FALL => self.fall(i),
                    MATCHED => {
                        self.has_matched = true;
                        self.tm[i] -= 1;
                        if self.tm[i] == 0 {
                            self.vanish(i);
                        }
                    }
                    _ => {}
                }
            }
        }
    }

    fn fall(&mut self, i: usize) {
        let b = i + W;
        if b < N && self.color[b] == 0 {
            self.tm[i] -= 1;
            if self.tm[i] <= 0 {
                self.move_cell(i, b);
                self.tm[b] = FALL_TICKS;
            }
        } else if b < N && (self.st[b] == FALL || self.st[b] == HOVER) {
            self.tm[i] = (self.tm[i] - 1).max(1); // follow the block below as soon as it moves
        } else {
            self.st[i] = LAND;
            self.tm[i] = LAND_TICKS;
            self.need_scan = true;
        }
    }

    /// A matched panel disappears; everything stacked on it becomes chain material.
    fn vanish(&mut self, i: usize) {
        self.clear_cell(i);
        let mut j = i;
        while j >= W {
            j -= W;
            if self.color[j] == 0 || self.gid[j] != 0 || !self.resting(j) {
                break;
            }
            self.chain[j] = 1;
        }
        self.need_support = true;
    }

    fn update_slab(&mut self, i: usize) {
        let r = self.slab_rect(i);
        let Rect { x0, y0, w, h } = r;
        let y1 = y0 + h - 1;
        match self.st[i] {
            HOVER => {
                if self.slab_tick(r) == 0 {
                    self.slab_set(r, FALL, FALL_TICKS);
                }
            }
            FALL => {
                let mut rest = y1 + 1 >= ROWS;
                let mut moving = false;
                if !rest {
                    for k in 0..w {
                        let c = (y1 + 1) * W + x0 + k;
                        if self.color[c] != 0 {
                            if self.st[c] == FALL || self.st[c] == HOVER {
                                moving = true;
                            } else {
                                rest = true;
                            }
                        }
                    }
                }
                if rest {
                    self.slab_set(r, NORMAL, 0);
                } else if moving {
                    self.slab_set(r, FALL, (self.tm[i] - 1).max(1));
                } else if self.slab_tick(r) <= 0 {
                    for y in (y0..=y1).rev() {
                        for k in 0..w {
                            self.move_cell(y * W + x0 + k, (y + 1) * W + x0 + k);
                        }
                    }
                    self.slab_set(Rect { y0: y0 + 1, ..r }, FALL, FALL_TICKS);
                }
            }
            MATCHED => {
                self.has_matched = true;
                if self.slab_tick(r) == 0 {
                    // Bottom row becomes the panels revealed during the crack (they may chain);
                    // the rest shrinks back to garbage. Unsupported ones hover, then fall.
                    for k in 0..w {
                        let c = y1 * W + x0 + k;
                        let col = self.reveal[c];
                        self.clear_cell(c);
                        self.color[c] = if col != 0 { col } else { self.rand_color() };
                        self.chain[c] = 1;
                        let below = c + W;
                        if below < N
                            && (self.color[below] == 0
                                || self.st[below] == HOVER
                                || self.st[below] == FALL)
                        {
                            self.set_state(c, HOVER, GARBAGE_HANG_TICKS); // hang before the drop
                        }
                    }
                    self.crack_hang = (GARBAGE_HANG_TICKS + FALL_TICKS * 4) as i64;
                    if h > 1 {
                        self.slab_set(Rect { h: h - 1, ..r }, NORMAL, 0);
                    }
                    self.need_scan = true;
                    self.need_support = true;
                }
            }
            _ => {}
        }
    }

    // --- support / gravity ------------------------------------------------------

    fn apply_support(&mut self) {
        self.need_support = false;
        let mut done = Seen::new();
        for y in (0..ROWS).rev() {
            for x in 0..W {
                let i = y * W + x;
                if self.color[i] == 0 {
                    continue;
                }
                if self.gid[i] != 0 {
                    if !done.has(self.gid[i]) {
                        done.add(self.gid[i]);
                        self.support_slab(i);
                    }
                    continue;
                }
                let b = i + W;
                if b >= N || !self.resting(i) {
                    continue;
                }
                if self.color[b] == 0 {
                    self.set_state(i, HOVER, HOVER_TICKS);
                } else if self.st[b] == HOVER || self.st[b] == FALL {
                    self.set_state(i, self.st[b], self.tm[b]); // join the column below
                }
            }
        }
    }

    fn support_slab(&mut self, i: usize) {
        if self.st[i] != NORMAL {
            return;
        }
        let r = self.slab_rect(i);
        let below = (r.y0 + r.h) * W + r.x0;
        if below >= N {
            return;
        }
        let mut join = None;
        for k in 0..r.w {
            let c = below + k;
            if self.color[c] == 0 {
                continue;
            }
            if self.st[c] == HOVER || self.st[c] == FALL {
                join = Some(c);
            } else {
                return; // resting on something
            }
        }
        match join {
            None => self.slab_set(r, HOVER, HOVER_TICKS),
            Some(c) => self.slab_set(r, self.st[c], self.tm[c]),
        }
    }

    // --- matching ---------------------------------------------------------------

    fn scan(&mut self) {
        self.need_scan = false;
        let mut mark = [false; N];
        for y in 0..ROWS {
            let mut run = 1;
            for x in 1..=W {
                let i = y * W + x;
                if x < W
                    && self.matchable(i)
                    && self.matchable(i - 1)
                    && self.color[i] == self.color[i - 1]
                {
                    run += 1;
                } else {
                    if run >= 3 {
                        for k in 0..run {
                            mark[i - 1 - k] = true;
                        }
                    }
                    run = 1;
                }
            }
        }
        for x in 0..W {
            let mut run = 1;
            for y in 1..=ROWS {
                let i = y * W + x;
                if y < ROWS
                    && self.matchable(i)
                    && self.matchable(i - W)
                    && self.color[i] == self.color[i - W]
                {
                    run += 1;
                } else {
                    if run >= 3 {
                        for k in 0..run {
                            mark[i - W - k * W] = true;
                        }
                    }
                    run = 1;
                }
            }
        }

        let idx: Vec<usize> = (0..N).filter(|&i| mark[i]).collect();
        let chained = idx.iter().any(|&i| self.chain[i] == 1);
        let n = idx.len();
        if n > 0 {
            let count = n as i32;
            let pops = POP_TICKS * count;
            let total = FLASH_TICKS + pops;
            for (k, &i) in idx.iter().enumerate() {
                self.set_state(i, MATCHED, total);
                self.aux[i] = POP_TICKS * (count - 1 - k as i32) | (pops << 16);
                self.chain[i] = 0;
            }
            self.has_matched = true;
            self.score += n as i64 * 10;
            if n >= 4 {
                for &w in combo_garbage(n) {
                    self.outbox.push(slab(w, 1));
                    self.sent += w as i64;
                }
                self.fx_combo = n as i64;
                self.score += (n as i64 - 3) * 20;
            }
            if chained {
                self.chain_n += 1;
                self.fx_chain = self.chain_n;
                self.best_chain = self.best_chain.max(self.chain_n);
                self.score += 50 * (self.chain_n - 1);
            }
            if n >= 4 || chained {
                self.stop_t = self.stop_t.max(STOP_TICKS);
                self.fx_t = FX_TICKS;
            }
            self.convert_touching(&idx, total);
        }
        // Anything that came to rest without matching is no longer part of a chain.
        for i in 0..N {
            if self.chain[i] != 0 && self.resting(i) {
                self.chain[i] = 0;
            }
        }
    }

    /// Garbage touching a match (and garbage touching that, transitively) starts cracking.
    /// It breaks apart in a ripple from where the match touched it: each cell's turn comes by
    /// its distance through the garbage from the matched panels, bottom row first on ties.
    fn convert_touching(&mut self, matched: &[usize], total: i32) {
        // Which slabs crack: everything reachable from the match through touching garbage.
        let mut todo: Vec<usize> = matched.to_vec();
        let mut seen = Seen::new();
        while let Some(i) = todo.pop() {
            let (near, count) = neighbours(i);
            for &j in &near[..count] {
                if self.gid[j] == 0 || seen.has(self.gid[j]) || self.st[j] != NORMAL {
                    continue;
                }
                seen.add(self.gid[j]);
                let r = self.slab_rect(j);
                for y in r.y0..r.y0 + r.h {
                    for k in 0..r.w {
                        todo.push(y * W + r.x0 + k);
                    }
                }
                // Decide now what the bottom row will become, so it can be revealed cell by cell.
                for k in 0..r.w {
                    self.reveal[(r.y0 + r.h - 1) * W + r.x0 + k] = self.rand_color();
                }
            }
        }
        if seen.n == 0 {
            return;
        }
        // Ripple: breadth-first distance from the matched panels through cracking cells.
        let mut dist = [-1i64; N];
        let mut queue: Vec<usize> = Vec::with_capacity(N);
        for &i in matched {
            let (near, count) = neighbours(i);
            for &j in &near[..count] {
                if self.gid[j] != 0 && seen.has(self.gid[j]) && dist[j] < 0 {
                    dist[j] = 1;
                    queue.push(j);
                }
            }
        }
        let mut head = 0;
        while head < queue.len() {
            let i = queue[head];
            head += 1;
            let (near, count) = neighbours(i);
            for &j in &near[..count] {
                if self.gid[j] != 0 && seen.has(self.gid[j]) && dist[j] < 0 {
                    dist[j] = dist[i] + 1;
                    queue.push(j);
                }
            }
        }
        // Order by distance, then lower rows first, then left to right.
        queue.sort_unstable_by_key(|&i| (dist[i], ROWS - 1 - i / W, i % W));
        let pops: i32 = queue
            .iter()
            .map(|&i| if self.reveal[i] != 0 { REVEAL_TICKS } else { SHELL_POP_TICKS })
            .sum();
        let mut elapsed = 0;
        for &i in &queue {
            elapsed += if self.reveal[i] != 0 { REVEAL_TICKS } else { SHELL_POP_TICKS };
            self.set_state(i, MATCHED, total + pops);
            self.aux[i] = (pops - elapsed) | (pops << 16);
        }
    }

    fn check_chain_end(&mut self) {
        for i in 0..N {
            if self.chain[i] != 0 || (self.st[i] == MATCHED && self.gid[i] == 0) {
                return;
            }
        }
        let rows = (self.chain_n - 1).min(BUF as i64);
        self.outbox.push(slab(W as i32, rows as i32));
        self.sent += W as i64 * rows;
        self.chain_n = 1;
    }

    // --- garbage in, rise -------------------------------------------------------

    fn feed_garbage(&mut self) {
        if self.gar_q.is_empty() {
            return;
        }
        if self.gar_t > 0 {
            self.gar_t -= 1;
        } else if !self.has_matched && self.chain_n == 1 && self.drop_garbage(self.gar_q[0]) {
            self.gar_q.remove(0);
            self.gar_t = GARBAGE_GAP;
        }
    }

    /// Spawns a slab at the top of the hidden buffer. Waits while that spot is occupied.
    fn drop_garbage(&mut self, slab: i32) -> bool {
        let w = (slab % 8) as usize;
        let h = (slab / 8) as usize;
        let x0 = if self.gar_side == 0 { 0 } else { W - w };
        for y in 0..h {
            for x in x0..x0 + w {
                if self.color[y * W + x] != 0 {
                    return false;
                }
            }
        }
        for y in 0..h {
            for x in x0..x0 + w {
                let c = y * W + x;
                self.color[c] = GARBAGE;
                self.gid[c] = self.next_gid as i32;
                self.set_state(c, FALL, FALL_TICKS);
            }
        }
        self.next_gid += 1;
        self.gar_side ^= 1;
        true
    }

    fn rise_stack(&mut self, input: u32) {
        if self.has_matched {
            return;
        }
        if self.topped() {
            // Pressed against the top: the stack can't rise, grace drains instead.
            if self.stop_t > 0 {
                self.stop_t -= 1;
            } else {
                self.health -= 1;
                self.lost = self.health <= 0;
            }
            return;
        }
        self.health = HEALTH_TICKS;
        if input & RAISE != 0 {
            self.stop_t = 0;
            self.rise += RAISE_SPEED;
        } else if self.stop_t > 0 {
            self.stop_t -= 1;
            return;
        } else {
            self.rise += 1 + self.age / SPEEDUP_TICKS;
        }
        if self.rise >= ROW_UNITS {
            self.rise = if self.push_row() { self.rise - ROW_UNITS } else { ROW_UNITS };
        }
    }

    fn push_row(&mut self) -> bool {
        if self.color[..W].iter().any(|&c| c != 0) {
            return false; // buffer is full to the brim; hold the stack until it drains
        }
        fn up<T: Copy + Default>(a: &mut [T; N]) {
            a.copy_within(W.., 0);
            a[N - W..].fill(T::default());
        }
        up(&mut self.color);
        up(&mut self.st);
        up(&mut self.tm);
        up(&mut self.aux);
        up(&mut self.chain);
        up(&mut self.gid);
        up(&mut self.reveal);
        self.color[N - W..].copy_from_slice(&self.next_row);
        self.next_row = self.make_row(ROWS - 1);
        self.cursor_y = (self.cursor_y - 1).max(TOP as i64);
        self.need_scan = true;
        true
    }

    // --- helpers ----------------------------------------------------------------

    /// Something is resting in the top visible row.
    pub fn topped(&self) -> bool {
        (0..W).any(|x| {
            let i = TOP * W + x;
            self.color[i] != 0 && self.st[i] != FALL && self.st[i] != HOVER
        })
    }

    fn resting(&self, i: usize) -> bool {
        self.st[i] == NORMAL || self.st[i] == LAND
    }

    fn matchable(&self, i: usize) -> bool {
        self.color[i] != 0 && self.color[i] <= COLORS && self.resting(i)
    }

    fn set_state(&mut self, i: usize, s: u8, t: i32) {
        self.st[i] = s;
        self.tm[i] = t;
        self.busy = true;
    }

    fn clear_cell(&mut self, i: usize) {
        self.color[i] = 0;
        self.st[i] = NORMAL;
        self.tm[i] = 0;
        self.aux[i] = 0;
        self.chain[i] = 0;
        self.gid[i] = 0;
        self.reveal[i] = 0;
    }

    fn move_cell(&mut self, from: usize, to: usize) {
        self.color[to] = self.color[from];
        self.st[to] = self.st[from];
        self.tm[to] = self.tm[from];
        self.aux[to] = self.aux[from];
        self.chain[to] = self.chain[from];
        self.gid[to] = self.gid[from];
        self.reveal[to] = self.reveal[from];
        self.clear_cell(from);
    }

    /// The (rectangular) slab containing cell i.
    fn slab_rect(&self, i: usize) -> Rect {
        let g = self.gid[i];
        let mut x0 = i % W;
        let mut y0 = i / W;
        while x0 > 0 && self.gid[y0 * W + x0 - 1] == g {
            x0 -= 1;
        }
        while y0 > 0 && self.gid[(y0 - 1) * W + x0] == g {
            y0 -= 1;
        }
        let mut w = 1;
        while x0 + w < W && self.gid[y0 * W + x0 + w] == g {
            w += 1;
        }
        let mut h = 1;
        while y0 + h < ROWS && self.gid[(y0 + h) * W + x0] == g {
            h += 1;
        }
        Rect { x0, y0, w, h }
    }

    fn slab_set(&mut self, r: Rect, s: u8, t: i32) {
        for y in r.y0..r.y0 + r.h {
            for k in 0..r.w {
                self.set_state(y * W + r.x0 + k, s, t);
            }
        }
    }

    /// Decrements every cell's timer in the slab; returns the new value.
    fn slab_tick(&mut self, r: Rect) -> i32 {
        let mut t = 0;
        for y in r.y0..r.y0 + r.h {
            for k in 0..r.w {
                let c = y * W + r.x0 + k;
                self.tm[c] -= 1;
                t = self.tm[c];
            }
        }
        t
    }

    /// A row of panels with no triples against itself or the two rows from `above` up.
    fn make_row(&mut self, above: usize) -> [u8; W] {
        let mut row = [0u8; W];
        for x in 0..W {
            loop {
                let c = self.rand_color();
                let h = x >= 2 && row[x - 1] == c && row[x - 2] == c;
                let v = above >= 1
                    && self.color[above * W + x] == c
                    && self.color[(above - 1) * W + x] == c;
                if !(h || v) {
                    row[x] = c;
                    break;
                }
            }
        }
        row
    }

    fn rand_color(&mut self) -> u8 {
        (self.rand() % COLORS as u32) as u8 + 1
    }

    fn rand(&mut self) -> u32 {
        // xorshift32
        let mut x = self.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.rng = x;
        x
    }
}
