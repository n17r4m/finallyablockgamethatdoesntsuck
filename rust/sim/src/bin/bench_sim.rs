//! How fast the rules run, measured on the recorded games.
//!   cargo run --release --bin bench_sim -- tests/golden/cpu_1.fbgr ...

use fbg_sim::Replay;
use std::hint::black_box;
use std::time::Instant;

const ROLLBACK: usize = 192; // the worst rollback the netcode allows

fn main() {
    let replays: Vec<Replay> = std::env::args()
        .skip(1)
        .map(|f| Replay::decode(&std::fs::read(f).unwrap()).unwrap())
        .collect();
    let mut ticks = 0u64;
    let mut stepping = 0f64;
    let mut worst_rollback = 0f64;
    let mut worst_copy = 0f64;
    let mut rollbacks = Vec::new();
    for _ in 0..5 {
        for r in &replays {
            let masks = input_table(r);
            let mut s = r.new_state();
            let start = Instant::now();
            for m in &masks {
                s.step(m.0, m.1);
            }
            stepping += start.elapsed().as_secs_f64();
            black_box(&s);
            ticks += masks.len() as u64;
            let mut s = r.new_state();
            for (t, m) in masks.iter().enumerate() {
                if t % 720 == 0 && t + ROLLBACK < masks.len() {
                    let start = Instant::now();
                    let mut copy = s.clone();
                    worst_copy = worst_copy.max(start.elapsed().as_secs_f64());
                    for later in &masks[t..t + ROLLBACK] {
                        copy.step(later.0, later.1);
                    }
                    let took = start.elapsed().as_secs_f64();
                    black_box(&copy);
                    worst_rollback = worst_rollback.max(took);
                    rollbacks.push(took);
                }
                s.step(m.0, m.1);
            }
        }
    }
    rollbacks.sort_by(f64::total_cmp);
    println!(
        "{ticks} ticks: {:.3} us/tick (two boards), {:.3}% of a core per match at 720 Hz",
        stepping / ticks as f64 * 1e6,
        stepping / ticks as f64 * 720.0 * 100.0
    );
    println!(
        "copy max {:.1} us; rollback of {ROLLBACK} ticks: p50 {:.0} us, p99 {:.0} us, max {:.0} us",
        worst_copy * 1e6,
        rollbacks[rollbacks.len() / 2] * 1e6,
        rollbacks[rollbacks.len() * 99 / 100] * 1e6,
        worst_rollback * 1e6
    );
}

fn input_table(r: &Replay) -> Vec<(u32, u32)> {
    let mut out = Vec::with_capacity(r.end_tick as usize);
    let (mut a, mut b) = (0, 0);
    let (mut i, mut j) = (0, 0);
    for t in 0..r.end_tick {
        if r.inputs[0].get(i).is_some_and(|e| e.tick == t) {
            a = r.inputs[0][i].mask;
            i += 1;
        }
        if r.inputs[1].get(j).is_some_and(|e| e.tick == t) {
            b = r.inputs[1][j].mask;
            j += 1;
        }
        out.push((a, b));
    }
    out
}
