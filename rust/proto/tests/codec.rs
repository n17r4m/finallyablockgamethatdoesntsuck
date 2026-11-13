//! Every message survives the trip, unknown fields and messages are skipped, limits hold, and
//! damage is an error, never a panic.

use fbg_proto::wire::*;
use fbg_proto::*;

fn input() -> InputMsg {
    InputMsg {
        seat: 1,
        frontier: 72_000,
        ack: -1,
        tick: 72_010,
        advantage: -3,
        changes: List::of(&[(71_990, 16), (71_995, 0), (72_000, 1 << 16 | 3 << 8 | 7 << 12), (72_000, -1)]),
        checks: List::of(&[(71_280, -5_000_000_000_123), (72_000, i64::MIN), (72_000, i64::MAX)]),
    }
}

fn clients() -> Vec<ClientMsg> {
    vec![
        ClientMsg::Hello { protocol: PROTOCOL, engine: 1, tick_hz: 720, name: "Zoë 🙂".into(), platform: "web_android".into(), features: features::CUSTOM_RULES, resume: [7; RESUME] },
        ClientMsg::Hello { protocol: 0, engine: 0, tick_hz: 0, name: "".into(), platform: "".into(), features: 0, resume: Token::default() },
        ClientMsg::Queue { mode: 0 },
        ClientMsg::Queue { mode: 7 },
        ClientMsg::Room { code: "KXQT".into(), rules: vec![] },
        ClientMsg::Room { code: "A1".into(), rules: vec![0, 1, 2, 255] },
        ClientMsg::Input(input()),
        ClientMsg::Input(InputMsg::default()),
        ClientMsg::Rematch,
        ClientMsg::Ping(u64::MAX),
    ]
}

fn servers() -> Vec<ServerMsg> {
    let mut seats = List::default();
    seats.push(SeatInfo { name: "Ann".into(), team: 0, platform: "linux".into() });
    seats.push(SeatInfo { name: "Bo".into(), team: 1, platform: "web".into() });
    vec![
        ServerMsg::Welcome { features: 0, resumed: 0 },
        ServerMsg::Welcome { features: 3, resumed: 41 },
        ServerMsg::Refused { code: Refusal::Update, text: "Please update.".into() },
        ServerMsg::Waiting { room: "".into() },
        ServerMsg::Waiting { room: "KXQT".into() },
        ServerMsg::Start { match_id: 1, seed: -42, seat: 1, rules: vec![9; 300], seats, resume: [255; RESUME] },
        ServerMsg::Start { match_id: 0, seed: 0, seat: 0, rules: vec![], seats: List::default(), resume: Token::default() },
        ServerMsg::Input(input()),
        ServerMsg::Result { winner: 1, draw: false, reason: EndReason::Stalled, tick: 9000 },
        ServerMsg::Result { winner: 0, draw: true, reason: EndReason::Played, tick: 0 },
        ServerMsg::Pong(12345),
        ServerMsg::Left { seat: 1 },
        ServerMsg::Notice("The server restarts after this game.".into()),
        ServerMsg::Away { seat: 1, away: true },
        ServerMsg::Away { seat: 0, away: false },
    ]
}

#[test]
fn every_message_survives_the_trip() {
    for m in clients() {
        assert_eq!(ClientMsg::decode(&m.encode()), Ok(Decoded::Msg(m.clone())), "{m:?}");
    }
    for m in servers() {
        assert_eq!(ServerMsg::decode(&m.encode()), Ok(Decoded::Msg(m.clone())), "{m:?}");
    }
}

#[test]
fn room_codes_ignore_case() {
    let m = ClientMsg::Room { code: "kxqt".into(), rules: vec![] };
    assert_eq!(ClientMsg::decode(&m.encode()), Ok(Decoded::Msg(ClientMsg::Room { code: "KXQT".into(), rules: vec![] })));
}

/// What lets the protocol grow: a newer sender's extra fields and messages are skipped.
#[test]
fn unknown_fields_and_messages_are_skipped() {
    let extra = |out: &mut Vec<u8>| {
        let mut w = Writer { out };
        w.uint(99, 12345);
        w.bytes(100, b"from the future");
        w.fixed64(101, -7);
        w.raw_varint((102 << 3) | FIXED32 as u64);
        w.out.extend_from_slice(&[1, 2, 3, 4]);
    };
    for m in clients() {
        let mut b = m.encode();
        extra(&mut b);
        assert_eq!(ClientMsg::decode(&b), Ok(Decoded::Msg(m.clone())), "{m:?}");
    }
    for m in servers() {
        let mut b = m.encode();
        extra(&mut b);
        assert_eq!(ServerMsg::decode(&b), Ok(Decoded::Msg(m.clone())), "{m:?}");
    }
    let mut b = vec![15];
    extra(&mut b);
    assert_eq!(ClientMsg::decode(&b), Ok(Decoded::Unknown(15)));
    let mut b = vec![0x80, 0x01]; // message 128, as a two-byte varint
    extra(&mut b);
    assert_eq!(ServerMsg::decode(&b), Ok(Decoded::Unknown(128)));
    // An unknown message still has to be well formed.
    assert_eq!(ServerMsg::decode(&[60, 0x0a, 5, 1]), Err(Damaged));
}

#[test]
fn limits_hold() {
    let hello = |name: &str, platform: &str| {
        let mut out = vec![1];
        let mut w = Writer { out: &mut out };
        w.bytes(4, name.as_bytes());
        w.bytes(5, platform.as_bytes());
        ClientMsg::decode(&out)
    };
    assert!(hello(&"a".repeat(MAX_NAME), "web").is_ok());
    assert_eq!(hello(&"a".repeat(MAX_NAME + 1), "web"), Err(Damaged));
    assert_eq!(hello("a", "web/../x"), Err(Damaged));
    assert_eq!(hello("a", &"w".repeat(MAX_PLATFORM + 1)), Err(Damaged));

    let room = |code: &str| {
        let mut out = vec![3];
        Writer { out: &mut out }.bytes(1, code.as_bytes());
        ClientMsg::decode(&out)
    };
    assert_eq!(room(""), Err(Damaged));
    assert_eq!(room("AB-C"), Err(Damaged));
    assert_eq!(room(&"A".repeat(MAX_ROOM + 1)), Err(Damaged));

    // A full input fits; one more change doesn't.
    let mut m = InputMsg::default();
    for k in 0..MAX_CHANGES {
        m.changes.push((k as i64, 1));
    }
    for k in 0..MAX_CHECKS {
        m.checks.push((k as i64, k as i64));
    }
    let full = ClientMsg::Input(m).encode();
    assert_eq!(ClientMsg::decode(&full), Ok(Decoded::Msg(ClientMsg::Input(m))));
    let mut out = vec![4];
    let mut w = Writer { out: &mut out };
    w.packed(6, (0..=MAX_CHANGES as u64).map(|_| 2));
    w.packed(7, (0..=MAX_CHANGES as u64).map(|_| 1));
    assert_eq!(ClientMsg::decode(&out), Err(Damaged));
    // Changes and masks must pair up.
    let mut out = vec![4];
    let mut w = Writer { out: &mut out };
    w.packed(6, [2, 2].into_iter());
    w.packed(7, [1].into_iter());
    assert_eq!(ClientMsg::decode(&out), Err(Damaged));
    // A mask is 32 bits.
    let mut out = vec![4];
    let mut w = Writer { out: &mut out };
    w.packed(6, [2].into_iter());
    w.packed(7, [1u64 << 32].into_iter());
    assert_eq!(ClientMsg::decode(&out), Err(Damaged));
}

#[test]
fn damage_is_an_error_not_a_panic() {
    let mut frames: Vec<Vec<u8>> = clients().iter().map(|m| m.encode()).collect();
    frames.extend(servers().iter().map(|m| m.encode()));
    let mut rng = 0x2545_f491u32;
    let mut next = || {
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        rng
    };
    for f in &frames {
        for n in 0..f.len() {
            let _ = ClientMsg::decode(&f[..n]);
            let _ = ServerMsg::decode(&f[..n]);
        }
        for _ in 0..2000 {
            let mut b = f.clone();
            let i = next() as usize % b.len();
            b[i] = next() as u8;
            if next() % 4 == 0 {
                b.truncate(next() as usize % (b.len() + 1));
            }
            let _ = ClientMsg::decode(&b);
            let _ = ServerMsg::decode(&b);
        }
    }
    // Varints past ten bytes, or with too much in the tenth.
    assert!(Reader::new(&[0xff; 11]).raw_varint().is_none());
    assert!(Reader::new(&[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x02]).raw_varint().is_none());
    assert_eq!(Reader::new(&[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01]).raw_varint(), Some(u64::MAX));
    // A length that runs past the end.
    assert_eq!(ClientMsg::decode(&[3, 0x0a, 0x7f, b'A']), Err(Damaged));
    // Field 0 doesn't exist.
    assert_eq!(ClientMsg::decode(&[2, 0x00, 0x01]), Err(Damaged));
}

#[test]
fn varints_and_zigzag() {
    for v in [0u64, 1, 127, 128, 16383, 16384, u32::MAX as u64, u64::MAX] {
        let mut out = vec![];
        Writer { out: &mut out }.raw_varint(v);
        assert_eq!(out.len(), varint_len(v), "{v}");
        assert_eq!(Reader::new(&out).raw_varint(), Some(v));
    }
    for v in [0i64, -1, 1, -64, 64, i64::MIN, i64::MAX] {
        assert_eq!(unzigzag(zigzag(v)), v);
    }
    assert_eq!(zigzag(-1), 1);
    assert_eq!(zigzag(1), 2);
}

/// What players send 60 times a second: a typical input is a third of protocol 2's 47 bytes.
#[test]
fn inputs_are_small() {
    let typical = InputMsg { seat: 0, frontier: 43_211, ack: 43_150, tick: 43_220, advantage: 2, changes: List::of(&[(43_205, 16)]), checks: List::default() };
    let n = ClientMsg::Input(typical).encode().len();
    assert!(n <= 17, "{n} bytes");
    let idle = InputMsg { frontier: 43_211, ack: 43_150, tick: 43_220, ..Default::default() };
    let n = ClientMsg::Input(idle).encode().len();
    assert!(n <= 11, "{n} bytes");
}

/// The exact bytes of a few messages, written out, so a second implementation (or protoc
/// --decode_raw, after the first byte) has something to check against.
#[test]
fn known_bytes() {
    assert_eq!(ClientMsg::Rematch.encode(), [5]);
    assert_eq!(ClientMsg::Queue { mode: 0 }.encode(), [2]);
    assert_eq!(ClientMsg::Ping(300).encode(), [6, 0x08, 0xac, 0x02]);
    assert_eq!(ClientMsg::Room { code: "AB".into(), rules: vec![] }.encode(), [3, 0x0a, 2, b'A', b'B']);
    assert_eq!(ServerMsg::Left { seat: 1 }.encode(), [23, 0x08, 1]);
    let m = InputMsg { frontier: 10, ack: -1, tick: 10, changes: List::of(&[(8, 16), (10, 0)]), ..Default::default() };
    // frontier 10 -> zigzag 20; ack -1 is 11 before it -> 21; tick is the frontier, so it's
    // left out; change ticks -2 from the
    // frontier, then +2 -> 3, 4; masks 16, 0.
    assert_eq!(ClientMsg::Input(m).encode(), [4, 0x10, 20, 0x18, 21, 0x32, 2, 3, 4, 0x3a, 2, 16, 0]);
}

#[test]
fn a_token_is_whole_or_damaged() {
    let mut hello = ClientMsg::Hello { protocol: PROTOCOL, engine: 1, tick_hz: 720, name: "A".into(), platform: "x".into(), features: 0, resume: [1; RESUME] }.encode();
    let n = hello.len();
    // field 7, length 16, then the token: say it's 15 long and drop a byte
    assert_eq!(hello[n - RESUME - 1], RESUME as u8);
    hello[n - RESUME - 1] = (RESUME - 1) as u8;
    hello.pop();
    assert_eq!(ClientMsg::decode(&hello), Err(Damaged));
}

#[test]
fn no_token_costs_no_bytes() {
    let plain = ClientMsg::Hello { protocol: PROTOCOL, engine: 1, tick_hz: 720, name: "A".into(), platform: "x".into(), features: 0, resume: Token::default() };
    let with = ClientMsg::Hello { protocol: PROTOCOL, engine: 1, tick_hz: 720, name: "A".into(), platform: "x".into(), features: 0, resume: [3; RESUME] };
    assert_eq!(with.encode().len(), plain.encode().len() + 2 + RESUME);
}
