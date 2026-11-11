//! A real server on a real socket, with clients that speak the protocol byte for byte.

use fbg_server::protocol::{ClientMsg, EndReason, InputMsg, ServerMsg, PROTOCOL};
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
                Some(Ok(Message::Binary(b))) => return Some(ServerMsg::decode(&b).expect("the server sent junk")),
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
        assert_eq!(c.recv().await, Some(ServerMsg::Welcome));
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
    ClientMsg::Hello { protocol: PROTOCOL, rules: RULES_VERSION, tick_hz: TICK_HZ, name: name.into(), platform: "test".into() }
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
    a.send(ClientMsg::Room(code.into())).await;
    assert_eq!(a.recv().await, Some(ServerMsg::Waiting));
    b.send(ClientMsg::Room(code.into())).await;
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
    for (protocol, rules, says) in [(PROTOCOL + 1, RULES_VERSION, "protocol"), (PROTOCOL, RULES_VERSION + 1, "rules")] {
        let mut c = Client::connect(&url).await;
        c.send(ClientMsg::Hello { protocol, rules, tick_hz: TICK_HZ, name: String::new(), platform: String::new() }).await;
        let Some(ServerMsg::Refused(why)) = c.recv().await else { panic!("expected a refusal") };
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
        a.send(ClientMsg::Queue).await;
        assert_eq!(a.recv().await, Some(ServerMsg::Waiting));
        b.send(ClientMsg::Queue).await;
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
    a.send(ClientMsg::Room("ONE".into())).await;
    assert_eq!(a.recv().await, Some(ServerMsg::Waiting));
    b.send(ClientMsg::Room("TWO".into())).await;
    assert_eq!(b.recv().await, Some(ServerMsg::Waiting));
    c.send(ClientMsg::Room("one".into())).await; // codes ignore case
    assert!(matches!(c.recv().await, Some(ServerMsg::Start { seat: 1, .. })));
    assert!(matches!(a.recv().await, Some(ServerMsg::Start { seat: 0, .. })));
}

#[tokio::test]
async fn inputs_reach_the_other_player_unchanged() {
    let url = start_server(Config::default()).await;
    let (mut a, mut b, _) = pair(&url, "RELAY").await;
    let m = InputMsg { frontier: 30, ack: -1, tick: 6, advantage: 3, changes: vec![(29, 16)], checks: vec![] };
    a.send(ClientMsg::Input(m.clone())).await;
    assert_eq!(b.recv().await, Some(ServerMsg::Input(m)));
}

#[tokio::test]
async fn a_message_that_breaks_the_rules_never_reaches_the_other_player() {
    let url = start_server(Config::default()).await;
    let (mut a, mut b, _) = pair(&url, "BAD").await;
    let m = InputMsg { frontier: 5, changes: vec![(1, 1 << 30)], ..Default::default() };
    a.send(ClientMsg::Input(m)).await;
    assert_eq!(b.recv().await, Some(ServerMsg::Result { winner: 1, reason: EndReason::BadInput, tick: 0 }));
    assert!(matches!(a.recv().await, Some(ServerMsg::Result { winner: 1, .. })));
}

#[tokio::test]
async fn leaving_forfeits_and_the_other_player_can_play_on() {
    let url = start_server(Config::default()).await;
    let (a, mut b, _) = pair(&url, "LEAVE").await;
    drop(a);
    assert!(matches!(b.recv().await, Some(ServerMsg::Result { winner: 1, reason: EndReason::Left, .. })));
    assert_eq!(b.recv().await, Some(ServerMsg::OpponentLeft));
    b.send(ClientMsg::Queue).await;
    assert_eq!(b.recv().await, Some(ServerMsg::Waiting));
}

#[tokio::test]
async fn inputs_still_in_flight_when_an_opponent_leaves_are_not_punished() {
    let url = start_server(Config::default()).await;
    let (a, mut b, _) = pair(&url, "LATE").await;
    drop(a);
    assert!(matches!(b.recv().await, Some(ServerMsg::Result { .. })));
    assert_eq!(b.recv().await, Some(ServerMsg::OpponentLeft));
    b.send(ClientMsg::Input(InputMsg::default())).await;
    b.send(ClientMsg::Rematch).await;
    b.send(ClientMsg::Ping(1)).await;
    assert_eq!(b.recv().await, Some(ServerMsg::Pong(1)));
}

#[tokio::test]
async fn someone_who_gives_up_waiting_is_not_matched() {
    let url = start_server(Config::default()).await;
    let mut gone = Client::hello(&url).await;
    gone.send(ClientMsg::Queue).await;
    assert_eq!(gone.recv().await, Some(ServerMsg::Waiting));
    drop(gone);
    tokio::time::sleep(Duration::from_millis(100)).await;
    let mut c = Client::hello(&url).await;
    c.send(ClientMsg::Queue).await;
    assert_eq!(c.recv().await, Some(ServerMsg::Waiting));
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
    for early in [ClientMsg::Queue, ClientMsg::Room("A".into()), ClientMsg::Input(InputMsg::default()), ClientMsg::Rematch] {
        let mut c = Client::connect(&url).await;
        c.send(early).await;
        assert_eq!(c.recv().await, None);
    }
    // Saying hello twice, and asking for a game while waiting for one.
    let mut c = Client::hello(&url).await;
    c.send(hello("Twice")).await;
    assert_eq!(c.recv().await, None);
    let mut c = Client::hello(&url).await;
    c.send(ClientMsg::Queue).await;
    assert_eq!(c.recv().await, Some(ServerMsg::Waiting));
    c.send(ClientMsg::Queue).await;
    assert_eq!(c.recv().await, None);

    a.send(ClientMsg::Ping(42)).await;
    assert_eq!(a.recv().await, Some(ServerMsg::Pong(42)));
    let m = InputMsg { frontier: 1, ack: -1, ..Default::default() };
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
    assert!(matches!(second.recv().await, Some(ServerMsg::Refused(_))));
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
    let mut changes = vec![(0i64, 32i32)];
    while sim.tick < hz {
        sim.step(32, 0);
    }
    a.send(ClientMsg::Input(InputMsg { frontier: hz - 1, ack: -1, tick: hz, advantage: 0, changes: std::mem::take(&mut changes), checks: vec![(hz, sim.checksum())] })).await;
    b.send(ClientMsg::Input(InputMsg { frontier: hz - 1, ack: -1, tick: hz, advantage: 0, changes: vec![], checks: vec![(hz, sim.checksum())] })).await;
    // b lies about the next second, and a tells the truth. The referee should say so.
    while sim.tick < 2 * hz {
        sim.step(32, 0);
    }
    tokio::time::sleep(Duration::from_millis(50)).await;
    a.send(ClientMsg::Input(InputMsg { frontier: 2 * hz - 1, ack: -1, tick: 2 * hz, advantage: 0, changes: vec![], checks: vec![(2 * hz, sim.checksum())] })).await;
    b.send(ClientMsg::Input(InputMsg { frontier: 2 * hz - 1, ack: -1, tick: 2 * hz, advantage: 0, changes: vec![], checks: vec![(2 * hz, !sim.checksum())] })).await;
    for c in [&mut a, &mut b] {
        assert_eq!(c.recv_event().await, Some(ServerMsg::Result { winner: 0, reason: EndReason::WrongState, tick: 2 * hz }));
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
