//! A real server on a real socket, with clients that speak the protocol byte for byte.

use fbg_server::protocol::{ClientMsg, EndReason, InputMsg, List, ServerMsg, PROTOCOL};
use fbg_server::{serve, Config};
use fbg_sim::consts::{RULES_VERSION, TICK_HZ};
use fbg_sim::{Replay, State};
use futures_util::{SinkExt, StreamExt};
use std::time::Duration;
use tokio::net::{TcpListener, TcpStream};
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};

const WAIT: Duration = Duration::from_secs(5);

struct Client(WebSocketStream<MaybeTlsStream<TcpStream>>);

impl Client {
    async fn connect(url: &str) -> Client {
        Client(connect_async(url).await.unwrap().0)
    }

    async fn raw(&mut self, bytes: Vec<u8>) {
        let _ = self.0.send(Message::binary(bytes)).await;
    }

    async fn send(&mut self, m: ClientMsg) {
        self.raw(m.encode()).await;
    }

    /// The next message, or None once the server has closed the connection.
    async fn recv(&mut self) -> Option<ServerMsg> {
        loop {
            match timeout(WAIT, self.0.next()).await.expect("the server went quiet") {
                Some(Ok(Message::Binary(b))) => return Some(ServerMsg::read(&b).expect("the server sent junk")),
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => return None,
                Some(Ok(_)) => {}
            }
        }
    }

    async fn hello(url: &str) -> Client {
        Client::hello_as(url, "Player").await
    }

    async fn hello_as(url: &str, name: &str) -> Client {
        let mut c = Client::connect(url).await;
        c.send(hello(name)).await;
        assert!(matches!(c.recv().await, Some(ServerMsg::Welcome { .. })));
        c
    }

    /// Skips relayed inputs until something else arrives.
    async fn recv_event(&mut self) -> Option<ServerMsg> {
        loop {
            match self.recv().await {
                Some(ServerMsg::Input(_)) => continue,
                other => return other,
            }
        }
    }
}

fn hello(name: &str) -> ClientMsg {
    ClientMsg::Hello { protocol: PROTOCOL, engine: RULES_VERSION as u32, tick_hz: TICK_HZ as u32, name: name.into(), platform: "test".into(), features: 1, resume: Default::default() }
}

async fn start_server(config: Config) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("ws://{}", listener.local_addr().unwrap());
    tokio::spawn(serve(listener, config));
    url
}

/// Two clients in a match by way of a room, returning them and the seed.
async fn pair(url: &str, code: &str) -> (Client, Client, i64) {
    let (mut a, mut b) = (Client::hello(url).await, Client::hello(url).await);
    a.send(ClientMsg::Room { code: code.into(), rules: vec![] }).await;
    assert!(matches!(a.recv().await, Some(ServerMsg::Waiting { .. })));
    b.send(ClientMsg::Room { code: code.into(), rules: vec![] }).await;
    let (sa, sb) = (a.recv().await.unwrap(), b.recv().await.unwrap());
    let (ServerMsg::Start { match_id: ma, seed: x, seat: 0, .. }, ServerMsg::Start { match_id: mb, seed: y, seat: 1, .. }) = (sa, sb) else {
        panic!("expected seats 0 and 1");
    };
    assert_eq!((ma, x), (mb, y));
    (a, b, x)
}

#[tokio::test]
async fn a_wrong_version_is_told_why_and_closed() {
    let url = start_server(Config::default()).await;
    for (protocol, engine, says) in [(PROTOCOL + 1, RULES_VERSION as u32, "protocol"), (PROTOCOL, RULES_VERSION as u32 + 1, "engine")] {
        let mut c = Client::connect(&url).await;
        c.send(ClientMsg::Hello { protocol, engine, tick_hz: TICK_HZ as u32, name: "".into(), platform: "".into(), features: 0, resume: Default::default() }).await;
        let Some(ServerMsg::Refused { text: why, .. }) = c.recv().await else { panic!("expected a refusal") };
        assert!(why.contains(says), "{why}");
        assert_eq!(c.recv().await, None);
    }
}

#[tokio::test]
async fn the_queue_pairs_players_and_each_match_gets_its_own_seed() {
    let url = start_server(Config::default()).await;
    let mut seeds = vec![];
    for _ in 0..4 {
        let (mut a, mut b) = (Client::hello(&url).await, Client::hello(&url).await);
        a.send(ClientMsg::Queue { mode: 0 }).await;
        assert!(matches!(a.recv().await, Some(ServerMsg::Waiting { .. })));
        b.send(ClientMsg::Queue { mode: 0 }).await;
        let Some(ServerMsg::Start { seed, .. }) = a.recv().await else { panic!() };
        seeds.push(seed);
    }
    seeds.dedup();
    assert_eq!(seeds.len(), 4, "random seeds shouldn't repeat");
}

#[tokio::test]
async fn room_codes_keep_games_apart() {
    let url = start_server(Config::default()).await;
    let (mut a, mut b, mut c) = (Client::hello(&url).await, Client::hello(&url).await, Client::hello(&url).await);
    a.send(ClientMsg::Room { code: "ONE".into(), rules: vec![] }).await;
    assert!(matches!(a.recv().await, Some(ServerMsg::Waiting { .. })));
    b.send(ClientMsg::Room { code: "TWO".into(), rules: vec![] }).await;
    assert!(matches!(b.recv().await, Some(ServerMsg::Waiting { .. })));
    c.send(ClientMsg::Room { code: "one".into(), rules: vec![] }).await; // codes ignore case
    assert!(matches!(c.recv().await, Some(ServerMsg::Start { seat: 1, .. })));
    assert!(matches!(a.recv().await, Some(ServerMsg::Start { seat: 0, .. })));
}

#[tokio::test]
async fn inputs_reach_the_other_player_unchanged() {
    let url = start_server(Config::default()).await;
    let (mut a, mut b, _) = pair(&url, "RELAY").await;
    let m = InputMsg { seat: 0, frontier: 30, ack: -1, tick: 6, advantage: 3, changes: vec![(29, 16)].into(), checks: vec![].into() };
    a.send(ClientMsg::Input(m.clone())).await;
    assert_eq!(b.recv().await, Some(ServerMsg::Input(m)));
}

#[tokio::test]
async fn a_message_that_breaks_the_rules_never_reaches_the_other_player() {
    let url = start_server(Config::default()).await;
    let (mut a, mut b, _) = pair(&url, "BAD").await;
    let m = InputMsg { frontier: 5, changes: vec![(1, 1 << 30)].into(), ..Default::default() };
    a.send(ClientMsg::Input(m)).await;
    assert_eq!(b.recv().await, Some(ServerMsg::Result { winner: 1, draw: false, reason: EndReason::BadInput, tick: 0 }));
    assert!(matches!(a.recv().await, Some(ServerMsg::Result { winner: 1, .. })));
}

#[tokio::test]
async fn leaving_forfeits_and_the_other_player_can_play_on() {
    let url = start_server(Config::default()).await;
    let (a, mut b, _) = pair(&url, "LEAVE").await;
    drop(a);
    assert!(matches!(b.recv().await, Some(ServerMsg::Result { winner: 1, reason: EndReason::Left, .. })));
    assert_eq!(b.recv().await, Some(ServerMsg::Left { seat: 0 }));
    b.send(ClientMsg::Queue { mode: 0 }).await;
    assert!(matches!(b.recv().await, Some(ServerMsg::Waiting { .. })));
}

#[tokio::test]
async fn inputs_still_in_flight_when_an_opponent_leaves_are_not_punished() {
    let url = start_server(Config::default()).await;
    let (a, mut b, _) = pair(&url, "LATE").await;
    drop(a);
    assert!(matches!(b.recv().await, Some(ServerMsg::Result { .. })));
    assert_eq!(b.recv().await, Some(ServerMsg::Left { seat: 0 }));
    b.send(ClientMsg::Input(InputMsg::default())).await;
    b.send(ClientMsg::Rematch).await;
    b.send(ClientMsg::Ping(1)).await;
    assert_eq!(b.recv().await, Some(ServerMsg::Pong(1)));
}

#[tokio::test]
async fn someone_who_gives_up_waiting_is_not_matched() {
    let url = start_server(Config::default()).await;
    let mut gone = Client::hello(&url).await;
    gone.send(ClientMsg::Queue { mode: 0 }).await;
    assert!(matches!(gone.recv().await, Some(ServerMsg::Waiting { .. })));
    drop(gone);
    tokio::time::sleep(Duration::from_millis(100)).await;
    let mut c = Client::hello(&url).await;
    c.send(ClientMsg::Queue { mode: 0 }).await;
    assert!(matches!(c.recv().await, Some(ServerMsg::Waiting { .. })));
}

#[tokio::test]
async fn junk_costs_the_sender_its_connection_and_nobody_else_anything() {
    let url = start_server(Config::default()).await;
    let (mut a, mut b, _) = pair(&url, "JUNK").await;
    for junk in [vec![], vec![255], vec![1, 2], vec![4; 500], vec![0xAB; 3000]] {
        let mut c = Client::connect(&url).await;
        c.raw(junk).await;
        assert_eq!(c.recv().await, None);
    }
    // Text frames too, and something much too big.
    let mut c = Client::connect(&url).await;
    let _ = c.0.send(Message::text("hello")).await;
    assert_eq!(c.recv().await, None);
    let mut c = Client::connect(&url).await;
    c.raw(vec![0; 1 << 20]).await;
    assert_eq!(c.recv().await, None);
    // Anything before saying hello.
    for early in [ClientMsg::Queue { mode: 0 }, ClientMsg::Room { code: "A".into(), rules: vec![] }, ClientMsg::Input(InputMsg::default()), ClientMsg::Rematch] {
        let mut c = Client::connect(&url).await;
        c.send(early).await;
        assert_eq!(c.recv().await, None);
    }
    // Saying hello twice, and asking for a game while waiting for one.
    let mut c = Client::hello(&url).await;
    c.send(hello("Twice")).await;
    assert_eq!(c.recv().await, None);
    let mut c = Client::hello(&url).await;
    c.send(ClientMsg::Queue { mode: 0 }).await;
    assert!(matches!(c.recv().await, Some(ServerMsg::Waiting { .. })));
    c.send(ClientMsg::Queue { mode: 0 }).await;
    assert_eq!(c.recv().await, None);

    a.send(ClientMsg::Ping(42)).await;
    assert_eq!(a.recv().await, Some(ServerMsg::Pong(42)));
    let m = InputMsg { seat: 0, frontier: 1, ack: -1, ..Default::default() };
    a.send(ClientMsg::Input(m.clone())).await;
    assert_eq!(b.recv().await, Some(ServerMsg::Input(m)));
}

#[tokio::test]
async fn flooding_costs_the_flooder_the_match() {
    let url = start_server(Config::default()).await;
    let (mut a, mut b, _) = pair(&url, "FLOOD").await;
    for t in 0..5000u64 {
        a.send(ClientMsg::Ping(t)).await;
    }
    assert!(matches!(b.recv_event().await, Some(ServerMsg::Result { winner: 1, reason: EndReason::Left, .. })));
}

#[tokio::test]
async fn a_silent_connection_is_closed() {
    let url = start_server(Config::default()).await;
    let mut c = Client::connect(&url).await;
    let quiet = timeout(Duration::from_secs(7), c.0.next()).await;
    assert!(quiet.is_ok(), "should be closed within the hello limit");
}

#[tokio::test]
async fn a_full_server_says_so() {
    let url = start_server(Config { max_connections: 1, ..Config::default() }).await;
    let _first = Client::hello(&url).await;
    let mut second = Client::connect(&url).await;
    assert!(matches!(second.recv().await, Some(ServerMsg::Refused { text: _, .. })));
    assert_eq!(second.recv().await, None);
}

/// A whole game: both players' moves, a winner, a rematch on a new seed, and a replay on disk
/// that stands up by itself.
#[tokio::test]
async fn a_whole_match_ends_on_the_refereed_result_and_saves_a_replay() {
    let dir = std::env::temp_dir().join(format!("fbg-server-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let url = start_server(Config { replay_dir: Some(dir.clone()), ..Config::default() }).await;
    let (mut a, mut b, seed) = pair(&url, "WHOLE").await;

    // Player 1 holds raise until the stack tops out, in faster than real time. The server caps
    // how far ahead of its clock a frontier may be, so real time has to pass as well: this
    // test only needs a short game, so it forfeits by hash if it can't finish.
    let mut sim = State::new(seed, false);
    let hz = i64::from(TICK_HZ);
    let mut changes: List<(i64, i32), 256> = List::of(&[(0i64, 32i32)]);
    while sim.tick < hz {
        sim.step(32, 0);
    }
    a.send(ClientMsg::Input(InputMsg { seat: 0, frontier: hz - 1, ack: -1, tick: hz, advantage: 0, changes: std::mem::take(&mut changes), checks: vec![(hz, sim.checksum())].into() })).await;
    b.send(ClientMsg::Input(InputMsg { seat: 0, frontier: hz - 1, ack: -1, tick: hz, advantage: 0, changes: vec![].into(), checks: vec![(hz, sim.checksum())].into() })).await;
    // b lies about the next second, and a tells the truth. The referee should say so.
    while sim.tick < 2 * hz {
        sim.step(32, 0);
    }
    tokio::time::sleep(Duration::from_millis(50)).await;
    a.send(ClientMsg::Input(InputMsg { seat: 0, frontier: 2 * hz - 1, ack: -1, tick: 2 * hz, advantage: 0, changes: vec![].into(), checks: vec![(2 * hz, sim.checksum())].into() })).await;
    b.send(ClientMsg::Input(InputMsg { seat: 0, frontier: 2 * hz - 1, ack: -1, tick: 2 * hz, advantage: 0, changes: vec![].into(), checks: vec![(2 * hz, !sim.checksum())].into() })).await;
    for c in [&mut a, &mut b] {
        assert_eq!(c.recv_event().await, Some(ServerMsg::Result { winner: 0, draw: false, reason: EndReason::WrongState, tick: 2 * hz }));
    }

    a.send(ClientMsg::Rematch).await;
    b.send(ClientMsg::Rematch).await;
    let Some(ServerMsg::Start { seed: second, seat: 0, .. }) = a.recv_event().await else { panic!("no rematch") };
    assert_ne!(second, seed);

    tokio::time::sleep(Duration::from_millis(200)).await;
    let files: Vec<_> = std::fs::read_dir(&dir).unwrap().flatten().collect();
    assert_eq!(files.len(), 1);
    let saved = Replay::decode(&std::fs::read(files[0].path()).unwrap()).unwrap();
    assert_eq!(saved.seed, seed);
    assert_eq!(saved.end_tick, 2 * hz as u64);
    saved.verify().unwrap();
    std::fs::remove_file(files[0].path()).unwrap();
    std::fs::remove_dir(&dir).unwrap();
}

#[tokio::test]
async fn a_room_plays_on_its_hosts_rules() {
    let url = start_server(Config::default()).await;
    let mut rules = fbg_sim::Rules::standard();
    rules.colors = 6;
    rules.swap = 30;
    let bytes = rules.encode();
    let (mut a, mut b) = (Client::hello(&url).await, Client::hello(&url).await);
    a.send(ClientMsg::Room { code: "SIX".into(), rules: bytes.clone() }).await;
    assert_eq!(a.recv().await, Some(ServerMsg::Waiting { room: "SIX".into() }));
    // Whoever joins brings no rules of their own.
    b.send(ClientMsg::Room { code: "SIX".into(), rules: vec![] }).await;
    for c in [&mut a, &mut b] {
        let Some(ServerMsg::Start { rules: got, seats, .. }) = c.recv().await else { panic!("no start") };
        assert_eq!(got, bytes);
        assert_eq!(seats.len(), 2);
    }
}

#[tokio::test]
async fn the_standard_rules_go_as_none_and_damaged_rules_are_turned_away() {
    let url = start_server(Config::default()).await;
    let (mut a, mut b) = (Client::hello(&url).await, Client::hello(&url).await);
    a.send(ClientMsg::Room { code: "STD".into(), rules: fbg_sim::Rules::standard().encode() }).await;
    assert!(matches!(a.recv().await, Some(ServerMsg::Waiting { .. })));
    b.send(ClientMsg::Room { code: "STD".into(), rules: vec![] }).await;
    assert!(matches!(b.recv().await, Some(ServerMsg::Start { rules, .. }) if rules.is_empty()));

    let mut c = Client::hello(&url).await;
    let mut bad = fbg_sim::Rules::standard().encode();
    bad[5] = 99; // 99 colours
    c.send(ClientMsg::Room { code: "BAD".into(), rules: bad }).await;
    assert!(matches!(c.recv().await, Some(ServerMsg::Notice(t)) if t.contains("can't be played")));
    // Still in the lobby, and free to try again.
    c.send(ClientMsg::Queue { mode: 0 }).await;
    assert!(matches!(c.recv().await, Some(ServerMsg::Waiting { .. })));
}

#[tokio::test]
async fn a_game_without_custom_rules_is_told_why_it_cant_join_one() {
    let url = start_server(Config::default()).await;
    let mut rules = fbg_sim::Rules::standard();
    rules.colors = 4;
    let mut host = Client::hello(&url).await;
    host.send(ClientMsg::Room { code: "FOUR".into(), rules: rules.encode() }).await;
    assert!(matches!(host.recv().await, Some(ServerMsg::Waiting { .. })));
    let mut old = Client::connect(&url).await;
    old.send(ClientMsg::Hello { protocol: PROTOCOL, engine: RULES_VERSION as u32, tick_hz: TICK_HZ as u32, name: "Old".into(), platform: "test".into(), features: 0, resume: Default::default() }).await;
    assert!(matches!(old.recv().await, Some(ServerMsg::Welcome { .. })));
    old.send(ClientMsg::Room { code: "FOUR".into(), rules: vec![] }).await;
    assert!(matches!(old.recv().await, Some(ServerMsg::Notice(t)) if t.contains("custom rules")));
}

#[tokio::test]
async fn messages_from_a_newer_game_are_skipped_not_punished() {
    let url = start_server(Config::default()).await;
    let mut c = Client::hello(&url).await;
    c.raw(vec![14, 0x08, 1]).await; // message 14, which this server has never heard of
    let mut ping = ClientMsg::Ping(5).encode();
    ping.extend_from_slice(&[0xa0, 0x06, 1]); // and a field 100 it doesn't know
    c.raw(ping).await;
    assert_eq!(c.recv().await, Some(ServerMsg::Pong(5)));
}

#[test]
fn any_valid_ruleset_fits_in_a_frame() {
    assert!(fbg_sim::rules::MAX_BYTES <= fbg_server::protocol::MAX_RULES);
}

/// Whoever still has the protocol 2 page open is told to reload, in protocol 2's own words.
#[tokio::test]
async fn a_protocol_2_game_is_told_to_update_in_words_it_can_read() {
    let url = start_server(Config::default()).await;
    let mut c = Client::connect(&url).await;
    let mut v2_hello = vec![1u8];
    for v in [2u16, 1, 720] {
        v2_hello.extend_from_slice(&v.to_le_bytes());
    }
    v2_hello.extend_from_slice(&[3, b'A', b'n', b'n', 3, b'w', b'e', b'b']);
    c.raw(v2_hello).await;
    let frame = loop {
        match timeout(WAIT, c.0.next()).await.unwrap() {
            Some(Ok(Message::Binary(b))) => break b,
            Some(Ok(_)) => continue,
            other => panic!("closed without a word: {other:?}"),
        }
    };
    assert_eq!(frame[0], 65);
    assert_eq!(frame[1] as usize, frame.len() - 2);
    assert!(std::str::from_utf8(&frame[2..]).unwrap().contains("Reload"));
}

fn hello_resuming(name: &str, resume: fbg_server::protocol::Token) -> ClientMsg {
    use fbg_server::protocol::features;
    ClientMsg::Hello { protocol: PROTOCOL, engine: RULES_VERSION as u32, tick_hz: TICK_HZ as u32, name: name.into(), platform: "test".into(), features: features::CUSTOM_RULES | features::RESUME, resume }
}

/// Two players who can resume, in a match: them, the match id and seat 0's token.
async fn resumable_pair(url: &str, code: &str) -> (Client, Client, u64, fbg_server::protocol::Token) {
    let mut a = Client::connect(url).await;
    a.send(hello_resuming("Ann", Default::default())).await;
    assert!(matches!(a.recv().await, Some(ServerMsg::Welcome { resumed: 0, .. })));
    let mut b = Client::connect(url).await;
    b.send(hello_resuming("Bo", Default::default())).await;
    assert!(matches!(b.recv().await, Some(ServerMsg::Welcome { resumed: 0, .. })));
    a.send(ClientMsg::Room { code: code.into(), rules: vec![] }).await;
    assert!(matches!(a.recv().await, Some(ServerMsg::Waiting { .. })));
    b.send(ClientMsg::Room { code: code.into(), rules: vec![] }).await;
    let Some(ServerMsg::Start { match_id, seat: 0, resume, .. }) = a.recv().await else { panic!("no start") };
    let Some(ServerMsg::Start { resume: other, .. }) = b.recv().await else { panic!("no start") };
    assert_ne!(resume, other, "each seat has its own token");
    assert_ne!(resume, fbg_server::protocol::Token::default());
    (a, b, match_id, resume)
}

#[tokio::test]
async fn a_dropped_player_gets_their_seat_back_with_the_token() {
    let url = start_server(Config::default()).await;
    let (a, mut b, mid, token) = resumable_pair(&url, "BACK").await;
    drop(a);
    assert_eq!(b.recv_event().await, Some(ServerMsg::Away { seat: 0, away: true }));
    let mut again = Client::connect(&url).await;
    again.send(hello_resuming("Ann", token)).await;
    assert_eq!(again.recv().await, Some(ServerMsg::Welcome { features: 3, resumed: mid }));
    assert_eq!(b.recv_event().await, Some(ServerMsg::Away { seat: 0, away: false }));
    // And plays on: its inputs reach the other player as seat 0's.
    let m = InputMsg { seat: 0, frontier: 30, ack: -1, tick: 6, advantage: 0, changes: vec![(29, 16)].into(), checks: vec![].into() };
    again.send(ClientMsg::Input(m.clone())).await;
    assert_eq!(b.recv().await, Some(ServerMsg::Input(m)));
}

#[tokio::test]
async fn a_token_takes_the_seat_from_a_connection_that_never_said_goodbye() {
    // A phone that switched networks leaves its old connection open on the server.
    let url = start_server(Config::default()).await;
    let (mut a, mut b, mid, token) = resumable_pair(&url, "SWITCH").await;
    let mut again = Client::connect(&url).await;
    again.send(hello_resuming("Ann", token)).await;
    assert_eq!(again.recv().await, Some(ServerMsg::Welcome { features: 3, resumed: mid }));
    assert_eq!(a.recv().await, None, "the old connection is let go");
    assert_eq!(b.recv_event().await, Some(ServerMsg::Away { seat: 0, away: false }));
}

#[tokio::test]
async fn a_wrong_token_is_a_new_arrival() {
    let url = start_server(Config::default()).await;
    let (_a, _b, _, mut token) = resumable_pair(&url, "WRONG").await;
    token[5] ^= 1;
    let mut c = Client::connect(&url).await;
    c.send(hello_resuming("Eve", token)).await;
    assert!(matches!(c.recv().await, Some(ServerMsg::Welcome { resumed: 0, .. })));
    c.send(ClientMsg::Queue { mode: 0 }).await;
    assert!(matches!(c.recv().await, Some(ServerMsg::Waiting { .. })), "and is in the lobby");
}

#[tokio::test]
async fn a_game_that_cant_resume_still_forfeits_on_leaving() {
    let url = start_server(Config::default()).await;
    let (a, mut b, _) = pair(&url, "OLDWAY").await;
    drop(a);
    assert!(matches!(b.recv_event().await, Some(ServerMsg::Result { winner: 1, reason: EndReason::Left, .. })));
}

#[tokio::test]
async fn a_player_who_never_comes_back_loses_and_the_other_is_free_to_go() {
    let url = start_server(Config::default()).await;
    let (a, mut b, _, _) = resumable_pair(&url, "GONE").await;
    drop(a);
    assert_eq!(b.recv_event().await, Some(ServerMsg::Away { seat: 0, away: true }));
    let m = InputMsg { seat: 1, frontier: 60, ack: -1, tick: 60, advantage: 0, changes: vec![].into(), checks: vec![].into() };
    b.send(ClientMsg::Input(m)).await;
    // The referee's stall limit is 10 s; it ends the match against whoever is holding it up.
    let ended = loop {
        match timeout(Duration::from_secs(15), b.0.next()).await.expect("no ending").and_then(|r| r.ok()) {
            Some(Message::Binary(bytes)) => match ServerMsg::read(&bytes) {
                Some(ServerMsg::Input(_)) => continue,
                other => break other,
            },
            Some(_) => continue,
            None => break None,
        }
    };
    assert!(matches!(ended, Some(ServerMsg::Result { winner: 1, reason: EndReason::Stalled, .. })), "{ended:?}");
    assert_eq!(b.recv().await, Some(ServerMsg::Left { seat: 0 }));
    b.send(ClientMsg::Queue { mode: 0 }).await;
    assert!(matches!(b.recv().await, Some(ServerMsg::Waiting { .. })));
}
