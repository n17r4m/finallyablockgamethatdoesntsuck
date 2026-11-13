//! Holds the Rust rules to `docs/engine-contract.md`: the recorded games, the hash vectors, and
//! what a hostile file can and can't do. Godot isn't needed to run these.

use fbg_sim::consts::*;
use fbg_sim::replay::{seal, InputEvent, SetupOp};
use fbg_sim::{Replay, State};
use std::path::{Path, PathBuf};

fn golden() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/golden")
}

fn read(name: &str) -> Vec<u8> {
    std::fs::read(golden().join(format!("{name}.fbgr"))).unwrap()
}

fn corpus() -> Vec<(String, Vec<u8>)> {
    let mut out: Vec<_> = std::fs::read_dir(golden())
        .unwrap()
        .flatten()
        .filter(|e| e.path().extension().is_some_and(|x| x == "fbgr"))
        .map(|e| {
            let name = e.path().file_stem().unwrap().to_string_lossy().into_owned();
            (name, std::fs::read(e.path()).unwrap())
        })
        .collect();
    out.sort();
    out
}

/// A small generator for the tests' own random choices, so failures reproduce.
struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> u32 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        (self.0 >> 33) as u32
    }

    fn below(&mut self, n: u32) -> u32 {
        self.next() % n
    }
}

fn random_mask(r: &mut Lcg) -> u32 {
    let mut m = target(r.below(5), r.below(12));
    if r.below(10) == 0 {
        m = 1 << r.below(4);
    }
    if r.below(5) < 2 {
        m |= SWAP;
    }
    if r.below(30) == 0 {
        m |= RAISE;
    }
    m
}

#[test]
fn recorded_games_verify_and_reencode_byte_for_byte() {
    let files = corpus();
    assert!(files.len() >= 47, "only {} replays found", files.len());
    for (name, bytes) in files {
        let r = Replay::decode(&bytes).unwrap_or_else(|e| panic!("{name}: {e}"));
        r.verify().unwrap_or_else(|e| panic!("{name}: {e}"));
        assert!(r.encode() == bytes, "{name} encodes differently");
    }
}

#[test]
fn hash_vectors_match_byte_for_byte() {
    // The vectors file is written with one field per line, so this needs no JSON library.
    let text = std::fs::read_to_string(golden().join("vectors.json")).unwrap();
    let field = |line: &str| line.split('"').nth(3).unwrap().to_string();
    let (mut bytes, mut hash, mut replay) = (String::new(), String::new(), String::new());
    let mut seen = 0;
    for line in text.lines().map(str::trim) {
        if line.starts_with("\"bytes\"") {
            bytes = field(line);
        } else if line.starts_with("\"hash\"") {
            hash = field(line);
        } else if line.starts_with("\"replay\"") {
            replay = field(line);
        } else if line.starts_with("\"tick\"") {
            let tick: i64 = line.split(':').nth(1).unwrap().trim().trim_end_matches(',').parse().unwrap();
            let r = Replay::decode(&read(&replay)).unwrap();
            let mut got = None;
            if tick == 0 {
                got = Some(r.new_state().canonical_bytes());
            } else {
                r.verify_with(|s| {
                    if s.tick == tick {
                        got = Some(s.canonical_bytes());
                    }
                })
                .unwrap();
            }
            let got = got.unwrap();
            assert_eq!(hex(&got), bytes, "{replay} at tick {tick}");
            assert_eq!(hex(&fbg_sim::hash64(&got).to_le_bytes()), hash, "{replay} at tick {tick}");
            seen += 1;
        }
    }
    assert_eq!(seen, 3);
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

#[test]
fn any_damage_is_refused() {
    let good = read("chain_2");
    for bit in 0..good.len() * 8 {
        let mut bad = good.clone();
        bad[bit / 8] ^= 1 << (bit % 8);
        assert!(Replay::decode(&bad).is_err(), "flipping bit {bit} went unnoticed");
    }
    for n in 0..good.len() {
        assert!(Replay::decode(&good[..n]).is_err(), "cutting to {n} bytes went unnoticed");
    }
}

#[test]
fn noise_with_a_valid_trailer_is_refused() {
    let mut r = Lcg(7);
    for i in 0..3000 {
        let size = 26 + r.below(200) as usize;
        let mut body: Vec<u8> = (0..size).map(|_| r.next() as u8).collect();
        if i % 2 == 0 {
            body[..5].copy_from_slice(b"FBGR\x01"); // get past the first checks
        }
        assert!(Replay::decode(&seal(body)).is_err());
    }
}

/// Corrupt the insides and fix the trailer, as a forger would. Whatever comes of it, nothing panics.
#[test]
fn resealed_corruption_never_panics() {
    let mut rng = Lcg(11);
    for name in ["garbage_3x1", "chain_3", "controls"] {
        let good = read(name);
        let body = &good[..good.len() - 8];
        for _ in 0..400 {
            let mut bad = body.to_vec();
            for _ in 0..1 + rng.below(4) {
                let at = 5 + rng.below(bad.len() as u32 - 5) as usize;
                bad[at] = rng.next() as u8;
            }
            if let Ok(r) = Replay::decode(&seal(bad)) {
                if r.end_tick < 40_000 {
                    let _ = r.verify();
                }
            }
        }
    }
}

#[test]
fn forged_games_fail_verification() {
    let good = Replay::decode(&read("garbage_3x1")).unwrap();
    good.verify().unwrap();
    let mut r = good.clone();
    r.seed ^= 1 << 8;
    assert!(r.verify().is_err(), "another seed");
    let mut r = good.clone();
    r.checkpoints.last_mut().unwrap().1 ^= 1;
    assert!(r.verify().is_err(), "a changed checkpoint");
    let mut r = good.clone();
    r.inputs[0].remove(0);
    assert!(r.verify().is_err(), "a removed input");
    let mut r = good.clone();
    r.inputs[0].insert(0, InputEvent { tick: 0, mask: LEFT });
    assert!(r.verify().is_err(), "an added input");
    let mut r = good.clone();
    r.checkpoints.push((r.end_tick + 1, 0));
    assert!(Replay::decode(&r.encode()).is_err(), "a checkpoint past the end");
    let mut r = good.clone();
    r.rules += 1;
    assert!(r.verify().is_err(), "another rules version");
    let mut r = good.clone();
    r.tick_hz += 1;
    assert!(r.verify().is_err(), "another tick rate");
    let mut r = good;
    r.setup.push(SetupOp::Put { board: 1, x: 0, row: 0, color: 1 });
    assert!(r.verify().is_err(), "a changed setup");
}

/// Every legal setup and input, far beyond real play. Runs with overflow checks on, so a wrong
/// index or a timer running away is a panic here even when no replay would have shown it.
/// A finished game does nothing, so this counts ticks in play.
#[test]
fn any_legal_game_runs_without_panicking() {
    let mut in_play = 0u64;
    let mut games = 0u64;
    let mut best_chain = 0;
    let mut best_combo = 0;
    while in_play < 3_000_000 {
        games += 1;
        let mut rng = Lcg(games);
        let solo = games % 8 == 0;
        let mut setup = Vec::new();
        for _ in 0..rng.below(600) {
            let board = rng.below(2) as u8;
            setup.push(match rng.below(8) {
                0 => SetupOp::Clear { board },
                1 | 2 => SetupOp::Garbage { board, w: 1 + rng.below(6) as u8, h: 1 + rng.below(12) as u8 },
                // Half the games pack a few colours low down, which forces big combos.
                _ if games % 2 == 0 => SetupOp::Put {
                    board,
                    x: rng.below(6) as u8,
                    row: rng.below(8) as u8,
                    color: 1 + rng.below(2) as u8,
                },
                _ => SetupOp::Put {
                    board,
                    x: rng.below(6) as u8,
                    row: rng.below(ROWS as u32) as u8,
                    color: rng.below(6) as u8,
                },
            });
        }
        let r = Replay {
            rules: RULES_VERSION,
            tick_hz: TICK_HZ,
            seed: rng.next() as i64 - (1 << 31),
            solo,
            end_tick: 0,
            start_hash: 0,
            setup,
            teams: vec![0, 1],
            ruleset: fbg_sim::Rules::shared_standard(),
            inputs: vec![Vec::new(), Vec::new()],
            checkpoints: Vec::new(),
        };
        let mut s = r.new_state();
        let (mut m0, mut m1) = (0, 0);
        while s.winner == -1 && s.tick < 200_000 {
            if s.tick % 12 == 0 {
                m0 = random_mask(&mut rng);
                m1 = random_mask(&mut rng);
            }
            s.step(m0, m1);
            in_play += 1;
            // Only a cracking slab holds a reveal colour, and those never move, which is why
            // nothing can tell if falling or a rising row carries it along.
            for b in &s.boards {
                for i in 0..N {
                    assert!(b.reveal[i] == 0 || (b.st[i] == fbg_sim::board::MATCHED && b.gid[i] != 0));
                }
            }
            best_combo = best_combo.max(s.boards[0].fx_combo).max(s.boards[1].fx_combo);
        }
        best_chain = best_chain.max(s.boards[0].best_chain).max(s.boards[1].best_chain);
    }
    println!("{games} games, {in_play} ticks in play, best chain {best_chain}, best combo {best_combo}");
    assert!(best_chain >= 3 && best_combo >= 8, "these games stopped reaching the deep rules");
}

/// Plays on from a copy made partway through each of several games.
#[test]
fn a_copy_plays_on_exactly_like_the_original() {
    let mut rng = Lcg(3);
    let mut in_play = 0;
    let mut game = 0;
    while in_play < 300_000 {
        game += 1;
        let mut a = State::new(game, false);
        let mut masks = Vec::new();
        let mut copies = Vec::new();
        while a.winner == -1 && a.tick < 30_000 {
            let m = (random_mask(&mut rng), random_mask(&mut rng));
            masks.push(m);
            if a.tick % 1_000 == 0 {
                copies.push(a.clone());
            }
            a.step(m.0, m.1);
        }
        in_play += masks.len();
        for mut c in copies {
            let from = c.tick as usize;
            for m in &masks[from..] {
                c.step(m.0, m.1);
            }
            assert!(c == a, "game {game}: a copy from tick {from} ended differently");
            assert_eq!(c.checksum(), a.checksum());
        }
    }
}

#[test]
fn swapping_the_players_mirrors_the_game() {
    let mut rng = Lcg(5);
    let mut in_play = 0;
    let mut game = 0;
    let mut wins = [0; 3];
    while in_play < 1_000_000 {
        game += 1;
        let mut a = State::new(game, false);
        let mut b = State::new(game, false);
        while a.winner == -1 && a.tick < 100_000 {
            // Mashing can clear panels faster than they rise, so one side only raises, to see both win.
            let (mut m0, mut m1) = (random_mask(&mut rng), random_mask(&mut rng));
            match game % 3 {
                0 => m0 = RAISE,
                1 => m1 = RAISE,
                _ => {}
            }
            a.step(m0, m1);
            b.step(m1, m0);
            assert!(a.boards[0] == b.boards[1] && a.boards[1] == b.boards[0], "game {game}, tick {}", a.tick);
            let mirrored = if b.winner == 0 || b.winner == 1 { 1 - b.winner } else { b.winner };
            assert_eq!(a.winner, mirrored, "game {game}, tick {}", a.tick);
            in_play += 1;
        }
        if a.winner >= 0 {
            wins[a.winner as usize] += 1;
        }
    }
    println!("{game} games, {in_play} ticks in play, wins {wins:?}");
    assert!(wins[0] > 0 && wins[1] > 0, "the mirror never saw both sides win");
}

#[test]
fn a_match_needs_two_teams_of_numbered_seats() {
    use fbg_sim::state::teams_error;
    for ok in [&[0u8, 1][..], &[1, 0, 1, 0], &[0, 1, 2], &[0, 0, 0, 1, 1, 1]] {
        assert_eq!(teams_error(ok), None, "{ok:?}");
    }
    for bad in [&[][..], &[0], &[0, 0], &[0, 2], &[1, 1], &[0, 1, 3], &[0, 1, 0, 1, 0, 1, 0, 1, 0]] {
        assert!(teams_error(bad).is_some(), "{bad:?}");
    }
}

/// Rotating a 2v2 by two seats swaps the teams; the game must be the same game, turned round.
/// Teams take turns aiming at both opponents, so the rotation must keep that order too.
#[test]
fn a_2v2_turned_round_is_the_same_game() {
    let mut rng = Lcg(9);
    let mut wins = [0; 3];
    for game in 1..=12 {
        let rules = fbg_sim::Rules::shared_standard();
        let mut a = State::seated(game, false, rules.clone(), &[0, 0, 1, 1]);
        let mut b = State::seated(game, false, rules, &[0, 0, 1, 1]);
        while a.winner == -1 && a.tick < 100_000 {
            let mut m: [u32; 4] = std::array::from_fn(|_| random_mask(&mut rng));
            let losing = (game % 2) as usize * 2; // a team tops out, so games end
            m[losing] = RAISE;
            m[losing + 1] = RAISE;
            let turned = [m[2], m[3], m[0], m[1]];
            a.step_all(&m);
            b.step_all(&turned);
            for p in 0..4 {
                assert!(a.boards[p] == b.boards[(p + 2) % 4], "game {game}, tick {}, board {p}", a.tick);
            }
            let mirrored = if b.winner == 0 || b.winner == 1 { 1 - b.winner } else { b.winner };
            assert_eq!(a.winner, mirrored, "game {game}, tick {}", a.tick);
        }
        if a.winner >= 0 {
            wins[a.winner as usize] += 1;
        }
    }
    println!("wins {wins:?}");
    assert!(wins[0] > 0 && wins[1] > 0, "the mirror never saw both teams win");
}

/// Plays random inputs on these teams and rules and records it the way a referee would.
fn record(seed: i64, teams: &[u8], rules: std::sync::Arc<fbg_sim::Rules>) -> Replay {
    let mut rng = Lcg(seed as u64);
    let mut s = State::seated(seed, false, rules.clone(), teams);
    let start_hash = s.checksum();
    let mut inputs = vec![Vec::new(); teams.len()];
    let mut checkpoints = Vec::new();
    let mut masks = vec![0u32; teams.len()];
    while s.winner == -1 && s.tick < 20 * TICK_HZ as i64 {
        if s.tick % 12 == 0 {
            for (p, m) in masks.iter_mut().enumerate() {
                *m = random_mask(&mut rng);
                inputs[p].push(InputEvent { tick: s.tick as u64, mask: *m });
            }
        }
        s.step_all(&masks);
        if s.tick % TICK_HZ as i64 == 0 || s.winner != -1 {
            checkpoints.push((s.tick as u64, s.checksum()));
        }
    }
    let end_tick = s.tick as u64;
    Replay {
        rules: RULES_VERSION,
        tick_hz: TICK_HZ,
        seed,
        solo: false,
        end_tick,
        start_hash,
        setup: vec![SetupOp::Garbage { board: teams.len() as u8 - 1, w: 3, h: 1 }],
        teams: teams.to_vec(),
        ruleset: rules,
        inputs,
        checkpoints,
    }
    .with_start_hash()
}

trait WithStartHash {
    fn with_start_hash(self) -> Self;
}

impl WithStartHash for Replay {
    /// The setup changes the start; recompute the hashes from it.
    fn with_start_hash(mut self) -> Replay {
        let mut s = self.new_state();
        self.start_hash = s.checksum();
        let n = self.teams.len();
        let mut next = vec![0; n];
        let mut masks = vec![0u32; n];
        let mut checks = Vec::new();
        for t in 0..self.end_tick {
            for p in 0..n {
                if let Some(e) = self.inputs[p].get(next[p]).filter(|e| e.tick == t) {
                    masks[p] = e.mask;
                    next[p] += 1;
                }
            }
            s.step_all(&masks);
            if s.tick % TICK_HZ as i64 == 0 || s.tick as u64 == self.end_tick {
                checks.push((s.tick as u64, s.checksum()));
            }
        }
        self.checkpoints = checks;
        self
    }
}

#[test]
fn a_match_format_1_cant_hold_is_written_as_format_2() {
    let mut six = fbg_sim::Rules::standard();
    six.colors = 6;
    let six = std::sync::Arc::new(six);
    for (teams, rules) in [
        (&[0u8, 1, 2][..], fbg_sim::Rules::shared_standard()),
        (&[0, 0, 1, 1], six.clone()),
        (&[0, 1], six),
    ] {
        let r = record(7, teams, rules);
        assert!(!r.fits_format_1());
        let bytes = r.encode();
        assert_eq!(bytes[4], 2, "{teams:?}");
        let back = Replay::decode(&bytes).unwrap();
        assert_eq!(back, r, "{teams:?}");
        back.verify().unwrap_or_else(|e| panic!("{teams:?}: {e}"));
        // The rules are part of the game: change them and it no longer verifies.
        let mut other = back.clone();
        other.ruleset = if *back.ruleset == fbg_sim::Rules::standard() {
            let mut r = fbg_sim::Rules::standard();
            r.colors = 4;
            std::sync::Arc::new(r)
        } else {
            fbg_sim::Rules::shared_standard()
        };
        assert!(other.verify().is_err(), "{teams:?} on other rules");
    }
    let one = record(3, &[0, 1], fbg_sim::Rules::shared_standard());
    assert!(one.fits_format_1());
    assert_eq!(one.encode()[4], 1, "a standard 1v1 is still format 1");
}

#[test]
fn format_2_refuses_bad_teams_and_rules() {
    let r = record(5, &[0, 1, 1], fbg_sim::Rules::shared_standard());
    let bytes = r.encode();
    let body = &bytes[..bytes.len() - 8];
    let at = 4 + 1 + 2 + 2 + 1 + 8; // the seat count
    for (what, edit) in [
        ("one seat", vec![(at, 1u8)]),
        ("one team", vec![(at + 1, 1)]),
        ("a team that skips one", vec![(at + 2, 2), (at + 3, 2)]),
        ("rules that don't decode", vec![(at + 4, 3)]),
    ] {
        let mut bad = body.to_vec();
        for (i, v) in edit {
            bad[i] = v;
        }
        assert!(Replay::decode(&seal(bad)).is_err(), "{what}");
    }
}
