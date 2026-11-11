//! The admin side: what the console sees and what its actions do to real players on real
//! sockets, what the store keeps across a restart, and who the console answers.

use fbg_server::admin::{serve_admin, AdminConfig};
use fbg_server::hub::{Action, AdminCmd, Snapshot};
use fbg_server::protocol::{ClientMsg, EndReason, ServerMsg, PROTOCOL};
use fbg_server::store::{self, Store};
use fbg_server::{run, Config, Extras};
use fbg_sim::consts::{RULES_VERSION, TICK_HZ};
use futures_util::{SinkExt, StreamExt};
use std::path::PathBuf;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};

const WAIT: Duration = Duration::from_secs(5);

struct Client(WebSocketStream<MaybeTlsStream<TcpStream>>);

impl Client {
    async fn hello(url: &str, name: &str) -> Client {
        let mut c = Client(connect_async(url).await.unwrap().0);
        c.send(ClientMsg::Hello { protocol: PROTOCOL, rules: RULES_VERSION, tick_hz: TICK_HZ, name: name.into(), platform: "test".into() }).await;
        assert_eq!(c.recv().await, Some(ServerMsg::Welcome));
        c
    }

    async fn send(&mut self, m: ClientMsg) {
        let _ = self.0.send(Message::binary(m.encode())).await;
    }

    async fn recv(&mut self) -> Option<ServerMsg> {
        loop {
            match timeout(WAIT, self.0.next()).await.expect("the server went quiet") {
                Some(Ok(Message::Binary(b))) => return Some(ServerMsg::decode(&b).expect("the server sent junk")),
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => return None,
                Some(Ok(_)) => {}
            }
        }
    }

    async fn recv_event(&mut self) -> Option<ServerMsg> {
        loop {
            match self.recv().await {
                Some(ServerMsg::Input(_)) => continue,
                other => return other,
            }
        }
    }
}

struct Server {
    url: String,
    admin: mpsc::Sender<AdminCmd>,
    task: JoinHandle<()>,
}

async fn start(store: Option<&PathBuf>) -> Server {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("ws://{}", listener.local_addr().unwrap());
    let (admin, rx) = mpsc::channel(16);
    let store = store.map(|p| Store::open(p).unwrap());
    let task = tokio::spawn(run(listener, Config::default(), Extras { store, admin: Some(rx) }));
    Server { url, admin, task }
}

impl Server {
    async fn snapshot(&self) -> Snapshot {
        let (tx, rx) = oneshot::channel();
        self.admin.send(AdminCmd::Snapshot(tx)).await.unwrap();
        rx.await.unwrap()
    }

    async fn act(&self, action: Action) -> Result<String, String> {
        let (tx, rx) = oneshot::channel();
        self.admin.send(AdminCmd::Act(action, tx)).await.unwrap();
        rx.await.unwrap()
    }

    /// Two named players in a match by way of a room.
    async fn pair(&self, a: &str, b: &str) -> (Client, Client, u64) {
        let (mut ca, mut cb) = (Client::hello(&self.url, a).await, Client::hello(&self.url, b).await);
        ca.send(ClientMsg::Room("ADMIN".into())).await;
        assert_eq!(ca.recv().await, Some(ServerMsg::Waiting));
        cb.send(ClientMsg::Room("ADMIN".into())).await;
        let Some(ServerMsg::Start { match_id, opponent, seat: 0, .. }) = ca.recv().await else { panic!("no start") };
        assert_eq!(opponent, b);
        let Some(ServerMsg::Start { opponent, seat: 1, .. }) = cb.recv().await else { panic!("no start") };
        assert_eq!(opponent, a);
        (ca, cb, match_id)
    }
}

fn temp_db(tag: &str) -> PathBuf {
    let p = std::env::temp_dir().join(format!("fbg-admin-{tag}-{}.db", std::process::id()));
    let _ = std::fs::remove_file(&p);
    p
}

#[tokio::test]
async fn the_console_sees_names_places_and_matches() {
    let s = start(None).await;
    let (_a, _b, mid) = s.pair("Ann", "Bob").await;
    let mut waiting = Client::hello(&s.url, "Cy").await;
    waiting.send(ClientMsg::Queue).await;
    assert_eq!(waiting.recv().await, Some(ServerMsg::Waiting));

    let snap = s.snapshot().await;
    assert_eq!(snap.protocol, PROTOCOL);
    assert_eq!(snap.matches.len(), 1);
    assert_eq!(snap.matches[0].names, ["Ann".to_string(), "Bob".to_string()]);
    let places: Vec<(String, String)> = snap.conns.iter().map(|c| (c.name.clone(), c.place.clone())).collect();
    let mid = format!("match {mid}");
    assert_eq!(places, [("Ann".into(), mid.clone()), ("Bob".into(), mid), ("Cy".into(), "queue".into())]);
    assert!(snap.conns.iter().all(|c| c.addr == "127.0.0.1" && c.platform == "test"));
}

#[tokio::test]
async fn a_notice_reaches_every_player() {
    let s = start(None).await;
    let (mut a, mut b, _) = s.pair("Ann", "Bob").await;
    assert_eq!(s.act(Action::Notice("Restart at nine".into())).await, Ok("told 2 players".into()));
    for c in [&mut a, &mut b] {
        assert_eq!(c.recv_event().await, Some(ServerMsg::Notice("Restart at nine".into())));
    }
    assert!(s.act(Action::Notice("  ".into())).await.is_err());
}

#[tokio::test]
async fn a_kick_forfeits_the_match_and_closes_the_connection() {
    let s = start(None).await;
    let (mut a, mut b, _) = s.pair("Ann", "Bob").await;
    let bob = s.snapshot().await.conns.iter().find(|c| c.name == "Bob").unwrap().id;
    assert!(s.act(Action::Kick(bob)).await.is_ok());
    assert_eq!(b.recv_event().await, Some(ServerMsg::Notice("You were removed from the server.".into())));
    assert_eq!(b.recv_event().await, None);
    assert!(matches!(a.recv_event().await, Some(ServerMsg::Result { winner: 0, reason: EndReason::Left, .. })));
    assert_eq!(a.recv_event().await, Some(ServerMsg::OpponentLeft));
    assert!(s.act(Action::Kick(bob)).await.is_err());
}

#[tokio::test]
async fn ending_a_match_is_a_draw_for_both() {
    let s = start(None).await;
    let (mut a, mut b, mid) = s.pair("Ann", "Bob").await;
    assert!(s.act(Action::End(mid)).await.is_ok());
    for c in [&mut a, &mut b] {
        assert!(matches!(c.recv_event().await, Some(ServerMsg::Result { winner: 2, reason: EndReason::Ended, .. })));
    }
    assert!(s.act(Action::End(mid)).await.is_err());
    assert!(s.act(Action::End(mid + 100)).await.is_err());
}

#[tokio::test]
async fn a_drain_refuses_new_games_and_exits_once_the_last_one_ends() {
    let s = start(None).await;
    let (mut a, mut b, mid) = s.pair("Ann", "Bob").await;
    let mut waiting = Client::hello(&s.url, "Cy").await;
    waiting.send(ClientMsg::Queue).await;
    assert_eq!(waiting.recv().await, Some(ServerMsg::Waiting));

    assert!(s.act(Action::Drain { on: true, exit: true }).await.is_ok());
    // Whoever was waiting is told, and so is whoever turns up.
    assert!(matches!(waiting.recv().await, Some(ServerMsg::Refused(why)) if why.contains("restarting")));
    let mut late = Client::hello(&s.url, "Di").await;
    late.send(ClientMsg::Queue).await;
    assert!(matches!(late.recv().await, Some(ServerMsg::Refused(why)) if why.contains("restarting")));
    for c in [&mut a, &mut b] {
        assert!(matches!(c.recv_event().await, Some(ServerMsg::Notice(_))));
    }
    // The game in progress carries on, and when it ends, so does the server.
    assert!(!s.task.is_finished());
    s.act(Action::End(mid)).await.unwrap();
    a.send(ClientMsg::Rematch).await;
    assert!(matches!(a.recv_event().await, Some(ServerMsg::Result { .. })));
    timeout(WAIT, s.task).await.expect("the server didn't stop").unwrap();
}

#[tokio::test]
async fn a_drain_can_be_called_off() {
    let s = start(None).await;
    s.act(Action::Drain { on: true, exit: false }).await.unwrap();
    assert!(s.snapshot().await.draining);
    s.act(Action::Drain { on: false, exit: false }).await.unwrap();
    let mut c = Client::hello(&s.url, "Ann").await;
    c.send(ClientMsg::Queue).await;
    assert_eq!(c.recv().await, Some(ServerMsg::Waiting));
}

#[tokio::test]
async fn a_ban_closes_and_refuses_that_address_and_survives_a_restart() {
    let db = temp_db("ban");
    let s = start(Some(&db)).await;
    let mut c = Client::hello(&s.url, "Ann").await;
    assert!(s.act(Action::Ban { addr: "nonsense".into(), note: String::new() }).await.is_err());
    assert_eq!(s.act(Action::Ban { addr: "127.0.0.1".into(), note: "testing".into() }).await, Ok("banned 127.0.0.1, closed 1 connections".into()));
    assert!(matches!(c.recv().await, Some(ServerMsg::Notice(_))));
    assert_eq!(c.recv().await, None);
    s.task.abort();

    let s = start(Some(&db)).await;
    let mut again = Client(connect_async(&s.url).await.unwrap().0);
    assert!(matches!(again.recv().await, Some(ServerMsg::Refused(why)) if why.contains("can't play")));
    assert!(s.act(Action::Unban("127.0.0.1".into())).await.is_ok());
    Client::hello(&s.url, "Ann").await;
    let _ = std::fs::remove_file(&db);
}

#[tokio::test]
async fn the_store_keeps_matches_and_numbering_across_a_restart() {
    let db = temp_db("store");
    let s = start(Some(&db)).await;
    let (_a, _b, first) = s.pair("Ann", "Bob").await;
    s.act(Action::End(first)).await.unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    s.task.abort();

    let s = start(Some(&db)).await;
    let (_a, _b, second) = s.pair("Cy", "Di").await;
    assert_eq!(second, first + 1, "match ids carry on from the database");
    tokio::time::sleep(Duration::from_millis(100)).await;

    let rows = store::history(&db, 10).unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[1].names, [Some("Ann".into()), Some("Bob".into())]);
    assert_eq!(rows[1].reason.as_deref(), Some("ended"));
    assert_eq!(rows[1].winner, Some(2));
    assert_eq!(rows[0].reason, None, "still playing");
    let stats = store::stats(&db, 0).unwrap();
    assert_eq!(stats.matches, 2);
    assert_eq!(stats.players, 1); // everyone here is 127.0.0.1
    let _ = std::fs::remove_file(&db);
}

/// One HTTP request by hand, returning the status code.
async fn http(addr: &str, request: String) -> u16 {
    let mut s = TcpStream::connect(addr).await.unwrap();
    s.write_all(request.as_bytes()).await.unwrap();
    let mut buf = vec![0u8; 64];
    let n = timeout(WAIT, s.read(&mut buf)).await.unwrap().unwrap();
    let head = String::from_utf8_lossy(&buf[..n]);
    head.split(' ').nth(1).unwrap().parse().unwrap()
}

async fn console(password: Option<&str>) -> (String, Server) {
    let s = start(None).await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap().to_string();
    let config = AdminConfig { password: password.map(Into::into), db: None, replay_dir: None };
    tokio::spawn(serve_admin(listener, s.admin.clone(), config));
    (addr, s)
}

#[tokio::test]
async fn the_console_only_answers_on_localhost_and_actions_need_its_header() {
    let (addr, _s) = console(None).await;
    let get = |host: &str| format!("GET /api/state HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n");
    assert_eq!(http(&addr, get(&addr)).await, 200);
    assert_eq!(http(&addr, get("localhost:47111")).await, 200);
    assert_eq!(http(&addr, get("evil.example:47111")).await, 403);
    let body = r#"{"notice":{"text":"hi"}}"#;
    let post = |extra: &str| {
        format!("POST /api/act HTTP/1.1\r\nHost: {addr}\r\nContent-Type: application/json\r\n{extra}Content-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len())
    };
    assert_eq!(http(&addr, post("")).await, 403);
    assert_eq!(http(&addr, post("X-Fbg-Admin: 1\r\n")).await, 200);
    assert_eq!(http(&addr, format!("GET /api/history HTTP/1.1\r\nHost: {addr}\r\nConnection: close\r\n\r\n")).await, 404);
}

#[tokio::test]
async fn with_a_password_the_console_asks_for_it_from_anywhere() {
    use base64::Engine;
    let (addr, _s) = console(Some("hunter2")).await;
    let get = |auth: &str| format!("GET /api/state HTTP/1.1\r\nHost: admin.example\r\n{auth}Connection: close\r\n\r\n");
    let basic = |pw: &str| format!("Authorization: Basic {}\r\n", base64::engine::general_purpose::STANDARD.encode(format!("me:{pw}")));
    assert_eq!(http(&addr, get("")).await, 401);
    assert_eq!(http(&addr, get(&basic("hunter3"))).await, 401);
    assert_eq!(http(&addr, get(&basic("hunter2"))).await, 200);
}
