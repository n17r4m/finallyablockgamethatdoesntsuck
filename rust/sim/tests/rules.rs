//! Holds `Rules` to the game as it plays today, to its byte layout, and to hostile input.
//! `tests/golden/standard.rules` is the standard ruleset's bytes; `tests/test_rules.gd` holds the
//! GDScript copy to the same file.

use fbg_sim::consts::*;
use fbg_sim::rules::*;
use std::path::{Path, PathBuf};

fn standard_file() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/golden/standard.rules")
}

#[test]
fn standard_is_valid_and_matches_the_recorded_bytes() {
    let r = Rules::standard();
    r.validate().unwrap();
    let bytes = r.encode();
    if std::env::var_os("FBG_WRITE_RULES").is_some() {
        std::fs::write(standard_file(), &bytes).unwrap();
    }
    assert_eq!(std::fs::read(standard_file()).unwrap(), bytes, "rerun with FBG_WRITE_RULES=1 if the layout changed on purpose");
    assert_eq!(Rules::decode(&bytes), Some(r));
}

#[test]
fn standard_plays_like_the_constants() {
    let r = Rules::standard();
    for age in (0..MAX_TICKS_TESTED).step_by(37).chain([0, 14399, 14400, 14401, 28800, 5_000_000]) {
        assert_eq!(r.rise_at(age), 1 + age / SPEEDUP_TICKS, "rise at {age}");
    }
    for n in 2..40 {
        assert_eq!(r.chain_rows_at(n), (n - 1).min(BUF as i64), "chain of {n}");
    }
    for n in 0..200 {
        let want: Vec<u8> = if n >= 4 { combo_garbage(n).iter().map(|&w| w as u8).collect() } else { vec![] };
        assert_eq!(r.combo_slabs(n), &want[..], "combo of {n}");
    }
}
const MAX_TICKS_TESTED: i64 = 200_000;

fn curve(fill: Fill, extend: bool, points: &[(i32, i32)]) -> Curve {
    Curve { fill, extend, points: points.to_vec() }
}

#[test]
fn curves_fill_in_and_carry_on() {
    let lin = curve(Fill::Linear, false, &[(10, 100), (20, 200), (30, 150)]);
    assert_eq!([lin.at(0), lin.at(10), lin.at(15), lin.at(20), lin.at(25), lin.at(29), lin.at(30), lin.at(99)], [100, 100, 150, 200, 175, 155, 150, 150]);
    let ext = curve(Fill::Linear, true, &[(0, 0), (3, 1)]);
    assert_eq!([ext.at(3), ext.at(5), ext.at(6), ext.at(30)], [1, 1, 2, 10]);
    let down = curve(Fill::Linear, true, &[(0, 10), (4, 7)]);
    assert_eq!([down.at(2), down.at(6), down.at(8)], [9, 6, 4]); // truncates toward zero, like GDScript
    let step = curve(Fill::Step, false, &[(0, 5), (10, 1)]);
    assert_eq!([step.at(9), step.at(10), step.at(1000)], [5, 1, 1]);
    let one = curve(Fill::Linear, false, &[(7, 3)]);
    assert_eq!([one.at(-5), one.at(7), one.at(1 << 40)], [3, 3, 3]);
}

#[test]
fn validate_names_what_breaks() {
    let bad = |f: &dyn Fn(&mut Rules)| {
        let mut r = Rules::standard();
        f(&mut r);
        let err = r.validate().unwrap_err();
        assert!(Rules::decode(&r.encode()).is_none(), "decode let through: {err}");
        err
    };
    assert!(bad(&|r| r.colors = 0).contains("colours"));
    assert!(bad(&|r| r.colors = 7).contains("colours"));
    assert!(bad(&|r| r.fall = 0).contains("fall"));
    assert!(bad(&|r| r.pop = MAX_POP + 1).contains("pop"));
    assert!(bad(&|r| r.repeat_rate = 0).contains("repeat_rate"));
    assert!(bad(&|r| r.time_slow = 0).contains("time_slow"));
    assert!(bad(&|r| r.time_slow = 17).contains("time_slow"));
    assert!(bad(&|r| r.flash = FOREVER + 1).contains("flash"));
    assert!(bad(&|r| r.rise.points.clear()).contains("rise"));
    assert!(bad(&|r| r.rise.points = vec![(5, 1), (5, 2)]).contains("left to right"));
    assert!(bad(&|r| r.rise.points = vec![(0, 1)]).contains("two points"));
    assert!(bad(&|r| r.rise.points[0].1 = -1).contains("rise"));
    assert!(bad(&|r| r.chain_rows.points[1].1 = 13).contains("chain_rows"));
    assert!(bad(&|r| r.combo_from = 2).contains("combo"));
    assert!(bad(&|r| r.combo.clear()).contains("combo"));
    assert!(bad(&|r| r.combo[0] = vec![7]).contains("wide"));

    // The ends of every range are playable.
    let mut r = Rules::standard();
    r.colors = 1;
    r.pop = MAX_POP;
    r.flash = FOREVER;
    r.time_slow = 1;
    r.repeat_delay = 0;
    r.health = 0;
    r.combo_from = 3;
    r.combo = vec![vec![], vec![1; 255]];
    r.rise = curve(Fill::Linear, true, &[(0, 0), (FOREVER, FOREVER)]);
    r.validate().unwrap();
    assert_eq!(Rules::decode(&r.encode()), Some(r.clone()));
    assert_ne!(r.fingerprint(), Rules::standard().fingerprint());
    assert_eq!(r.rise_at(2_000_000), 2_000_000);
    assert_eq!(r.rise_at(1 << 40), FOREVER as i64); // held, so a game-long sum fits
}

#[test]
fn decode_refuses_without_panicking() {
    let good = Rules::standard().encode();
    for n in 0..good.len() {
        assert!(Rules::decode(&good[..n]).is_none(), "cut at {n}");
    }
    let mut longer = good.clone();
    longer.push(0);
    assert!(Rules::decode(&longer).is_none());
    // Every single-byte change either decodes to something valid or is refused.
    let mut rng = 0x9e37_79b9u32;
    for i in 0..good.len() {
        for _ in 0..64 {
            rng ^= rng << 13;
            rng ^= rng >> 17;
            rng ^= rng << 5;
            let mut b = good.clone();
            b[i] = rng as u8;
            if let Some(r) = Rules::decode(&b) {
                r.validate().unwrap();
                assert_eq!(r.encode(), b);
            }
        }
    }
    // Random garbage.
    for len in 0..300 {
        let b: Vec<u8> = (0..len).map(|k| (k as u32).wrapping_mul(2654435761).rotate_left(len as u32) as u8).collect();
        let _ = Rules::decode(&b);
    }
}
