//! What the referee decides, with no sockets or clocks: honest games agree with the recorded
//! corpus, and each way of lying ends the match against the liar and nobody else.

use fbg_server::protocol::{ClientMsg, EndReason, InputMsg, ServerMsg};
use fbg_server::referee::{Referee, MAX_FUTURE, STALL_LIMIT};
use fbg_sim::consts::{SWAP, TICK_HZ};
use fbg_sim::{Replay, State};
use std::fs;
use std::path::PathBuf;

const HZ: i64 = TICK_HZ as i64;

fn corpus(name: &str) -> Replay {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/golden").join(name);
    Replay::decode(&fs::read(path).unwrap()).unwrap()
}

fn msg(frontier: i64, changes: Vec<(i64, i32)>, checks: Vec<(i64, i64)>) -> InputMsg {
    InputMsg { frontier, ack: -1, tick: frontier, advantage: 0, changes, checks }
}

/// Plays a recorded game through the referee in one-second batches, both players honest.
/// `tamper` may change what player `seat` says about a batch.
fn play(r: &Replay, mut tamper: impl FnMut(usize, &mut InputMsg)) -> Referee {
    let mut referee = Referee::new(r.seed);
    let mut s = r.new_state();
    let mut masks = [0u32; 2];
    let mut next = [0usize; 2];
    let mut from = 0i64;
    while from < r.end_tick as i64 && referee.outcome().is_none() {
        let to = (from + HZ).min(r.end_tick as i64);
        let mut changes: [Vec<(i64, i32)>; 2] = [vec![], vec![]];
        let mut checks = vec![];
        for t in from..to {
            for p in 0..2 {
                if let Some(e) = r.inputs[p].get(next[p]).filter(|e| e.tick as i64 == t) {
                    masks[p] = e.mask;
                    changes[p].push((t, e.mask as i32));
                    next[p] += 1;
                }
            }
            s.step(masks[0], masks[1]);
            if s.tick % HZ == 0 {
                checks.push((s.tick, s.checksum()));
            }
        }
        for p in 0..2 {
            let mut m = msg(to - 1, std::mem::take(&mut changes[p]), checks.clone());
            m.tick = to;
            tamper(p, &mut m);
            referee.input(p, &m, to);
        }
        from = to;
    }
    referee
}

#[test]
fn honest_games_end_as_recorded_and_their_replays_verify() {
    for name in ["cpu_1.fbgr", "cpu_2.fbgr", "cpu_slabs_above_and_below.fbgr", "garbage_two_sided.fbgr"] {
        let recorded = corpus(name);
        if !recorded.setup.is_empty() {
            continue; // the server only ever starts from a fresh board
        }
        let end = recorded.verify().unwrap();
        let referee = play(&recorded, |_, _| {});
        assert_eq!(referee.tick(), end.tick.min(referee.tick()), "{name}");
        match referee.outcome() {
            Some(o) => {
                assert_eq!(o.reason, EndReason::Played, "{name}");
                assert_eq!(i64::from(o.winner), end.winner, "{name}");
            }
            None => assert_eq!(end.winner, -1, "{name}"),
        }
        let saved = Replay::decode(&referee.replay().unwrap().encode()).unwrap();
        assert_eq!(saved.verify().unwrap().winner, end.winner, "{name}");
    }
}

#[test]
fn a_lying_hash_loses_to_the_honest_player_in_either_seat() {
    let r = corpus("cpu_1.fbgr");
    for liar in 0..2 {
        let referee = play(&r, |p, m| {
            if p == liar {
                for c in &mut m.checks {
                    c.1 ^= 1;
                }
            }
        });
        let o = referee.outcome().expect("the lie should end the match");
        assert_eq!(o.reason, EndReason::WrongState);
        assert_eq!(usize::from(o.winner), 1 - liar);
    }
}

#[test]
fn inputs_that_differ_from_a_players_own_hashes_cost_that_player() {
    // A client that plays one thing and reports the hashes of another.
    let r = corpus("cpu_1.fbgr");
    let referee = play(&r, |p, m| {
        if p == 1 {
            m.changes.clear();
        }
    });
    let o = referee.outcome().unwrap();
    assert_eq!(o.reason, EndReason::WrongState);
    assert_eq!(o.winner, 2, "both hashes are now wrong: the referee only has the inputs it was sent");
}

#[test]
fn hashes_can_only_be_checked_once_and_late_ones_are_harmless() {
    let mut a = Referee::new(1);
    a.input(0, &msg(HZ, vec![], vec![]), HZ);
    a.input(1, &msg(HZ, vec![], vec![]), HZ);
    let mut s = State::new(1, false);
    for _ in 0..HZ {
        s.step(0, 0);
    }
    let good = (HZ, s.checksum());
    let mut m = msg(HZ, vec![], vec![good]);
    m.tick = HZ;
    assert!(a.input(0, &m, HZ));
    // The same checkpoint again, now wrong: it has been settled.
    m.checks[0].1 ^= 1;
    assert!(a.input(0, &m, HZ));
    assert!(a.outcome().is_none());
}

#[test]
fn impossible_messages_forfeit() {
    let cases: Vec<(&str, InputMsg)> = vec![
        ("a mask outside the input bits", msg(10, vec![(5, 1 << 30)], vec![])),
        ("a change past its own frontier", msg(10, vec![(11, SWAP as i32)], vec![])),
        ("a frontier far past the clock", msg(100 + MAX_FUTURE + 1, vec![], vec![])),
        ("a hash at a tick that has no hash", msg(10, vec![], vec![(HZ + 1, 0)])),
        ("a hash from the future", msg(10, vec![], vec![(HZ * 9, 0)])),
    ];
    for (what, m) in cases {
        for seat in 0..2 {
            let mut r = Referee::new(7);
            assert!(!r.input(seat, &m, 100), "{what}");
            let o = r.outcome().unwrap();
            assert_eq!(o.reason, EndReason::BadInput, "{what}");
            assert_eq!(usize::from(o.winner), 1 - seat, "{what}");
        }
    }
}

#[test]
fn resends_change_nothing() {
    // A client resends everything unacknowledged in every packet.
    let end = HZ - 1;
    let (mut a, mut b) = (Referee::new(3), Referee::new(3));
    let first = msg(100, vec![(50, SWAP as i32)], vec![]);
    let second = msg(end, vec![(50, SWAP as i32), (150, 0)], vec![]);
    for seat in 0..2 {
        a.input(seat, &first, HZ);
        a.input(seat, &first, HZ);
        a.input(seat, &second, HZ);
        b.input(seat, &first, HZ);
        b.input(seat, &msg(end, vec![(150, 0)], vec![]), HZ);
    }
    assert_eq!(a.tick(), HZ);
    let (ra, rb) = (a.replay().unwrap(), b.replay().unwrap());
    assert_eq!(ra, rb);
    assert_eq!(ra.inputs[0].len(), 2, "the resent change must count once");
}

#[test]
fn a_change_rewriting_a_final_tick_is_ignored_like_the_peer_ignores_it() {
    let end = HZ - 1;
    let mut r = Referee::new(3);
    r.input(0, &msg(100, vec![], vec![]), HZ);
    r.input(0, &msg(end, vec![(50, SWAP as i32)], vec![]), HZ);
    r.input(1, &msg(end, vec![], vec![]), HZ);
    let mut clean = State::new(3, false);
    for _ in 0..HZ {
        clean.step(0, 0);
    }
    let replay = r.replay().unwrap();
    assert_eq!(replay.checkpoints, vec![(HZ as u64, clean.checksum())]);
    assert!(replay.inputs[0].is_empty());
    assert!(r.outcome().is_none());
}

#[test]
fn whoever_holds_the_match_up_forfeits() {
    for stuck in 0..2 {
        let mut r = Referee::new(9);
        let free = 1 - stuck;
        r.input(stuck, &msg(100, vec![], vec![]), 100);
        r.input(free, &msg(200, vec![], vec![]), 100);
        r.check_clock(100 + STALL_LIMIT);
        assert!(r.outcome().is_none(), "the limit itself is allowed");
        r.input(free, &msg(280, vec![], vec![]), 100 + STALL_LIMIT);
        r.check_clock(101 + STALL_LIMIT);
        let o = r.outcome().unwrap();
        assert_eq!(o.reason, EndReason::Stalled);
        assert_eq!(usize::from(o.winner), free);
    }
}

#[test]
fn a_slow_match_is_not_a_stalled_one() {
    // Clients drop ticks after a hitch, so a match falls behind the wall clock for good.
    // Only a frontier that has stopped moving counts.
    let mut r = Referee::new(4);
    for k in 0..200 {
        let now = (k + 1) * STALL_LIMIT / 4;
        let frontier = k * 10;
        r.input(0, &msg(frontier, vec![], vec![]), now);
        r.input(1, &msg(frontier, vec![], vec![]), now);
        r.check_clock(now);
    }
    assert!(r.outcome().is_none());
}

#[test]
fn nothing_after_the_end_changes_the_outcome() {
    let mut r = Referee::new(5);
    r.forfeit(0, EndReason::Left);
    let first = r.outcome();
    assert!(r.input(1, &msg(1 << 40, vec![(5, -1)], vec![]), 0));
    r.forfeit(1, EndReason::Stalled);
    r.check_clock(1 << 40);
    assert_eq!(r.outcome(), first);
}

#[test]
fn hostile_bytes_never_panic() {
    let mut x = 0x2545F4914F6CDD1Du64;
    let mut next = move || {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        x
    };
    let real = [
        ClientMsg::Hello { protocol: 1, rules: 1, tick_hz: 720 }.encode(),
        ClientMsg::Room("ABC123".into()).encode(),
        ClientMsg::Input(msg(10, vec![(5, 1)], vec![(720, 9)])).encode(),
    ];
    for _ in 0..200_000 {
        let mut b = real[next() as usize % real.len()].clone();
        for _ in 0..1 + next() % 4 {
            let i = next() as usize % b.len();
            b[i] = next() as u8;
        }
        b.truncate(next() as usize % (b.len() + 1));
        if let Some(ClientMsg::Input(m)) = ClientMsg::decode(&b) {
            let mut r = Referee::new(1);
            r.input(0, &m, 100);
            r.input(1, &m, 100);
        }
        let _ = ServerMsg::decode(&b);
    }
    // A count claiming far more than the message holds.
    let mut lying = ClientMsg::Input(InputMsg::default()).encode();
    lying[33] = 0xFF;
    lying[34] = 0x00;
    assert_eq!(ClientMsg::decode(&lying), None);
}

#[test]
fn every_message_survives_the_trip() {
    let input = InputMsg { frontier: 9, ack: -1, tick: 4, advantage: 1 << 40, changes: vec![(1, 2), (3, -4)], checks: vec![(720, -5)] };
    for m in [
        ClientMsg::Hello { protocol: 1, rules: 2, tick_hz: 720 },
        ClientMsg::Queue,
        ClientMsg::Room("A1".into()),
        ClientMsg::Input(input.clone()),
        ClientMsg::Rematch,
        ClientMsg::Ping(u64::MAX),
    ] {
        assert_eq!(ClientMsg::decode(&m.encode()), Some(m));
    }
    for m in [
        ServerMsg::Welcome,
        ServerMsg::Refused("no".into()),
        ServerMsg::Waiting,
        ServerMsg::Start { match_id: 7, seed: 1 << 31, seat: 1 },
        ServerMsg::Input(input),
        ServerMsg::Result { winner: 2, reason: EndReason::TooLong, tick: 5 },
        ServerMsg::Pong(1),
        ServerMsg::OpponentLeft,
    ] {
        assert_eq!(ServerMsg::decode(&m.encode()), Some(m));
    }
}
