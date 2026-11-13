//! Connections, the lobby and running matches. One task owns all of it and everything else
//! talks to that task, so there are no locks and a match can't be seen half-updated. The admin
//! console is one more thing that talks to it, through `AdminCmd`.

use crate::protocol::{clean_name, features, ClientMsg, Decoded, EndReason, InputMsg, List, Refusal, SeatInfo, ServerMsg, Text, Token, MAX_RULES, PROTOCOL};
use crate::referee::{Outcome, Referee};
use crate::store::{Loaded, Op, Seat, Store};
use fbg_sim::consts::{BUF, RULES_VERSION, TICK_HZ, W};
use fbg_sim::Rules;
use futures_util::{SinkExt, StreamExt};
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::net::IpAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::Message;

const HELLO_LIMIT: Duration = Duration::from_secs(5);
const CLOCK_EVERY: Duration = Duration::from_millis(250);
const SAMPLE_EVERY: Duration = Duration::from_secs(60);
const PING_EVERY: Duration = Duration::from_secs(2);
const MAX_MESSAGES_PER_SECOND: u32 = 1000; // far above any display rate
const OUTGOING_QUEUE: usize = 512;
/// The biggest a frame can be: a room with the largest ruleset there is. Inputs are far smaller.
const MAX_FRAME: usize = MAX_RULES + 64;
/// What this server can do beyond protocol 3's core.
const FEATURES: u64 = features::CUSTOM_RULES | features::RESUME;

const OUTDATED: &str = "This game is out of date. Reload the page, or update it.";
const DRAINING: &str = "The server is restarting for an update. Try again in a minute.";
const BANNED: &str = "This address can't play on this server.";

#[derive(Clone)]
pub struct Config {
    pub max_connections: usize,
    pub replay_dir: Option<PathBuf>,
    /// Take the player's address from X-Real-IP or X-Forwarded-For, when the connection comes
    /// from this machine. Only for a reverse proxy that sets them.
    pub trust_proxy: bool,
}

impl Default for Config {
    fn default() -> Self {
        Config { max_connections: 4096, replay_dir: None, trust_proxy: false }
    }
}

/// What `run` can be given besides the listener.
#[derive(Default)]
pub struct Extras {
    pub store: Option<(Store, Loaded)>,
    pub admin: Option<mpsc::Receiver<AdminCmd>>,
}

/// What the admin console can ask of the hub. Actions answer with a line for the console.
pub enum AdminCmd {
    Snapshot(oneshot::Sender<Snapshot>),
    Watch(u64, oneshot::Sender<Option<Watch>>),
    Act(Action, oneshot::Sender<Result<String, String>>),
}

#[derive(Debug)]
pub enum Action {
    Kick(u64),
    End(u64),
    Notice(String),
    /// Stop starting matches. With `exit`, the server stops once the last one ends.
    Drain { on: bool, exit: bool },
    Ban { addr: String, note: String },
    Unban(String),
}

#[derive(Serialize)]
pub struct Snapshot {
    pub version: &'static str,
    pub protocol: u32,
    pub rules: u16,
    pub uptime_s: u64,
    pub draining: bool,
    pub exit_when_drained: bool,
    pub conns: Vec<ConnInfo>,
    pub matches: Vec<MatchInfo>,
}

#[derive(Serialize)]
pub struct ConnInfo {
    pub id: u64,
    pub name: String,
    pub addr: String,
    pub platform: String,
    pub place: String, // "new", "lobby", "queue", "room CODE" or "match N"
    pub rtt_ms: Option<u32>,
    pub age_s: u64,
    pub here_s: u64, // how long they've been where they are
}

#[derive(Serialize)]
pub struct MatchInfo {
    pub id: u64,
    pub seed: i64,
    pub conns: [u64; 2],
    pub names: [String; 2],
    pub age_s: u64,
    pub clock: i64,     // the server's tick
    pub refereed: i64,  // how far the referee has played
    pub frontiers: [i64; 2],
    pub late: [i64; 2], // worst input lateness, ticks
    pub over: Option<String>,
    pub away: [bool; 2], // connection dropped; the seat is held for its token
}

/// One match's boards as the referee has them, for watching from the console.
#[derive(Serialize)]
pub struct Watch {
    pub id: u64,
    pub tick: i64,
    pub names: [String; 2],
    pub over: Option<String>,
    pub boards: Vec<BoardView>,
}

#[derive(Serialize)]
pub struct BoardView {
    pub cells: Vec<u8>, // visible rows only, top row first, 0 empty
    pub next_row: Vec<u8>,
    pub cursor: [i64; 2],
    pub score: i64,
    pub chain: i64,
    pub health: i64,
    pub incoming: usize,
    pub lost: bool,
}

enum Event {
    /// A protocol 2 game, which can only read protocol 2.
    Outdated(u64),
    Opened(u64, mpsc::Sender<Vec<u8>>, IpAddr),
    Message(u64, Box<ClientMsg>),
    Rtt(u64, u32),
    Junk(u64),
    Closed(u64),
}

#[derive(PartialEq)]
enum Place {
    New,
    Lobby,
    Waiting,
    Playing(u64),
}

struct Conn {
    tx: mpsc::Sender<Vec<u8>>,
    place: Place,
    placed: Instant,
    opened: Instant,
    window: Instant,
    messages: u32,
    addr: IpAddr,
    name: String,
    platform: String,
    features: u64, // what its game said it can do
    rtt_ms: Option<u32>,
}

/// Someone waiting for a friend with the same code, and the rules the match will have.
struct Room {
    host: u64,
    rules: Arc<Rules>,
    bytes: Vec<u8>, // as the host sent them; empty for standard
}

struct Match {
    conns: [u64; 2],
    rules: Arc<Rules>,
    rules_bytes: Vec<u8>,
    names: [String; 2],
    seed: i64,
    referee: Referee,
    started: Instant,
    rematch: [bool; 2],
    announced: bool,
    /// Each seat's resume token, and whether its connection has dropped, since when.
    tokens: [Token; 2],
    away: [Option<Instant>; 2],
}

struct Hub {
    conns: HashMap<u64, Conn>,
    matches: HashMap<u64, Match>,
    queue: Option<u64>,
    rooms: HashMap<String, Room>,
    next_match: u64,
    config: Config,
    store: Option<Store>,
    bans: HashSet<String>,
    draining: bool,
    exit_when_drained: bool,
    born: Instant,
}

/// Runs the server on a listener that's already bound, until the process ends.
pub async fn serve(listener: TcpListener, config: Config) {
    run(listener, config, Extras::default()).await
}

/// Runs the server until the process ends, or until a drain asked to exit and the last match
/// has finished.
pub async fn run(listener: TcpListener, config: Config, extras: Extras) {
    let (events, mut inbox) = mpsc::channel::<Event>(4096);
    let accepting = tokio::spawn(accept_loop(listener, events, config.trust_proxy));
    let (store, loaded) = match extras.store {
        Some((s, l)) => (Some(s), Some(l)),
        None => (None, None),
    };
    let mut hub = Hub {
        conns: HashMap::new(),
        matches: HashMap::new(),
        queue: None,
        rooms: HashMap::new(),
        next_match: loaded.as_ref().map_or(1, |l| l.next_match),
        config,
        store,
        bans: loaded.map(|l| l.bans.into_iter().collect()).unwrap_or_default(),
        draining: false,
        exit_when_drained: false,
        born: Instant::now(),
    };
    let (_keep, mut admin) = match extras.admin {
        Some(rx) => (None, rx),
        None => {
            let (tx, rx) = mpsc::channel(1);
            (Some(tx), rx) // never sends, so the branch below never fires
        }
    };
    let mut clock = tokio::time::interval(CLOCK_EVERY);
    let mut sample = tokio::time::interval(SAMPLE_EVERY);
    loop {
        tokio::select! {
            event = inbox.recv() => match event {
                Some(event) => hub.handle(event),
                None => break,
            },
            Some(cmd) = admin.recv() => hub.on_admin(cmd),
            _ = clock.tick() => hub.on_clock(),
            _ = sample.tick() => hub.on_sample(),
        }
        if hub.exit_when_drained && hub.matches.is_empty() {
            println!("drained: stopping");
            break;
        }
    }
    accepting.abort();
    if let Some(store) = &hub.store {
        store.flush();
    }
}

async fn accept_loop(listener: TcpListener, events: mpsc::Sender<Event>, trust_proxy: bool) {
    let mut next_id = 1u64;
    loop {
        let Ok((stream, peer)) = listener.accept().await else {
            tokio::time::sleep(Duration::from_millis(50)).await;
            continue;
        };
        let id = next_id;
        next_id += 1;
        let trust = trust_proxy && peer.ip().is_loopback();
        tokio::spawn(run_connection(id, stream, peer.ip(), trust, events.clone()));
    }
}

/// The address a reverse proxy says the player connected from.
fn forwarded_for(req: &Request) -> Option<IpAddr> {
    let real = req.headers().get("x-real-ip").and_then(|v| v.to_str().ok());
    let forwarded = req.headers().get("x-forwarded-for").and_then(|v| v.to_str().ok()).and_then(|v| v.rsplit(',').next());
    real.or(forwarded)?.trim().parse().ok()
}

/// One player's socket. Rollback needs inputs now, not a fuller packet later: hence no Nagle.
async fn run_connection(id: u64, stream: TcpStream, peer: IpAddr, trust_proxy: bool, events: mpsc::Sender<Event>) {
    let _ = stream.set_nodelay(true);
    let config = WebSocketConfig::default().max_message_size(Some(MAX_FRAME)).max_frame_size(Some(MAX_FRAME));
    let addr = Arc::new(Mutex::new(peer));
    let seen = addr.clone();
    let callback = move |req: &Request, res: Response| {
        if trust_proxy {
            if let Some(ip) = forwarded_for(req) {
                *seen.lock().unwrap() = ip;
            }
        }
        Ok(res)
    };
    let handshake = tokio_tungstenite::accept_hdr_async_with_config(stream, callback, Some(config));
    let Ok(Ok(socket)) = tokio::time::timeout(HELLO_LIMIT, handshake).await else {
        return;
    };
    let addr = *addr.lock().unwrap();
    let (mut sink, mut source) = socket.split();
    let (tx, mut rx) = mpsc::channel::<Vec<u8>>(OUTGOING_QUEUE);
    if events.send(Event::Opened(id, tx, addr)).await.is_err() {
        return;
    }
    // WebSocket pings measure the round trip for the console. Browsers answer them by themselves.
    let born = Instant::now();
    let writer = tokio::spawn(async move {
        let mut ping = tokio::time::interval(PING_EVERY);
        loop {
            tokio::select! {
                bytes = rx.recv() => match bytes {
                    Some(bytes) => if sink.send(Message::binary(bytes)).await.is_err() { break },
                    None => break,
                },
                _ = ping.tick() => {
                    let stamp = (born.elapsed().as_micros() as u64).to_le_bytes();
                    if sink.send(Message::Ping(stamp.to_vec().into())).await.is_err() {
                        break;
                    }
                }
            }
        }
        let _ = sink.close().await;
    });
    while let Some(Ok(frame)) = source.next().await {
        let event = match frame {
            // A protocol 2 game's hello (1, then protocol 2 as u16) can't be a protocol 3
            // message. Tell it to update in words it reads, rather than just hanging up.
            Message::Binary(bytes) if bytes.len() >= 3 && bytes[..3] == [1, 2, 0] => Event::Outdated(id),
            Message::Binary(bytes) => match ClientMsg::decode(&bytes) {
                Ok(Decoded::Msg(msg)) => Event::Message(id, Box::new(msg)),
                Ok(Decoded::Unknown(_)) => continue, // from a newer game; it'll manage without
                Err(_) => Event::Junk(id),
            },
            Message::Close(_) => break,
            Message::Pong(stamp) => {
                let Ok(stamp) = <[u8; 8]>::try_from(&stamp[..]) else { continue };
                let sent = u64::from_le_bytes(stamp);
                let now = born.elapsed().as_micros() as u64;
                if sent > now {
                    continue; // not one of ours
                }
                Event::Rtt(id, ((now - sent) / 1000).min(u32::MAX as u64) as u32)
            }
            Message::Ping(_) => continue,
            _ => Event::Junk(id),
        };
        if events.send(event).await.is_err() {
            break;
        }
    }
    let _ = events.send(Event::Closed(id)).await;
    writer.abort();
}

fn new_token() -> Token {
    let mut t = Token::default();
    let _ = getrandom::fill(&mut t);
    t[0] |= 1; // never all zeros, which means none
    t
}

fn new_seed() -> i64 {
    let mut bytes = [0u8; 4];
    // With no OS randomness the match can still be played; it just has a guessable seed.
    let _ = getrandom::fill(&mut bytes);
    i64::from(u32::from_le_bytes(bytes))
}

pub fn name_of(reason: EndReason) -> &'static str {
    match reason {
        EndReason::Played => "played",
        EndReason::Left => "left",
        EndReason::Stalled => "stalled",
        EndReason::WrongState => "wrong_state",
        EndReason::BadInput => "bad_input",
        EndReason::TooLong => "too_long",
        EndReason::Ended => "ended",
    }
}

fn describe(o: &Outcome) -> String {
    let who = match o.winner {
        0 | 1 => format!("seat {} won", o.winner),
        _ => "draw".into(),
    };
    format!("{who}, {}", name_of(o.reason))
}

impl Hub {
    fn handle(&mut self, event: Event) {
        match event {
            Event::Opened(id, tx, addr) => {
                let refusal = if self.bans.contains(&addr.to_string()) {
                    Some(BANNED)
                } else if self.conns.len() >= self.config.max_connections {
                    Some("The server is full")
                } else {
                    None
                };
                if let Some(why) = refusal {
                    let code = if why == BANNED { Refusal::Banned } else { Refusal::Full };
                    let _ = tx.try_send(ServerMsg::Refused { code, text: why.into() }.encode());
                    return; // dropping tx ends the writer, which closes the socket
                }
                let now = Instant::now();
                self.conns.insert(
                    id,
                    Conn { tx, place: Place::New, placed: now, opened: now, window: now, messages: 0, addr, name: String::new(), platform: String::new(), features: 0, rtt_ms: None },
                );
            }
            Event::Outdated(id) => {
                if let Some(c) = self.conns.get(&id) {
                    // Protocol 2's refusal: 65, a length byte, the text.
                    let mut v2 = vec![65, OUTDATED.len() as u8];
                    v2.extend_from_slice(OUTDATED.as_bytes());
                    let _ = c.tx.try_send(v2);
                }
                self.forget(id);
            }
            Event::Message(id, msg) => {
                if self.over_rate(id) {
                    self.drop_conn(id);
                } else {
                    self.on_message(id, msg);
                }
            }
            Event::Rtt(id, ms) => {
                if let Some(c) = self.conns.get_mut(&id) {
                    c.rtt_ms = Some(ms);
                }
            }
            Event::Junk(id) | Event::Closed(id) => self.drop_conn(id),
        }
    }

    fn over_rate(&mut self, id: u64) -> bool {
        let Some(c) = self.conns.get_mut(&id) else { return false };
        if c.window.elapsed() >= Duration::from_secs(1) {
            c.window = Instant::now();
            c.messages = 0;
        }
        c.messages += 1;
        c.messages > MAX_MESSAGES_PER_SECOND
    }

    fn send(&mut self, id: u64, msg: &ServerMsg) {
        let Some(c) = self.conns.get(&id) else { return };
        // A client that can't keep up is gone in all but name, and must not hold anyone else.
        if c.tx.try_send(msg.encode()).is_err() {
            self.drop_conn(id);
        }
    }

    fn refuse(&mut self, id: u64, code: Refusal, why: String) {
        self.send(id, &ServerMsg::Refused { code, text: why });
        self.forget(id);
    }

    fn on_message(&mut self, id: u64, msg: Box<ClientMsg>) {
        let Some(place) = self.conns.get(&id).map(|c| &c.place) else { return };
        let playing = if let Place::Playing(m) = place { Some(*m) } else { None };
        match *msg {
            ClientMsg::Hello { protocol, engine, tick_hz, name, platform, features, resume } if *place == Place::New => {
                if protocol != PROTOCOL {
                    self.refuse(id, Refusal::Update, format!("This game speaks protocol {protocol}, the server {PROTOCOL}. Please update."));
                } else if engine != RULES_VERSION as u32 || tick_hz != TICK_HZ as u32 {
                    self.refuse(id, Refusal::Update, format!("This game has engine {engine}, the server {RULES_VERSION}. Please update."));
                } else {
                    if let Some(c) = self.conns.get_mut(&id) {
                        c.name = clean_name(&name);
                        c.platform = platform.to_string();
                        c.features = features;
                    }
                    let resumed = if resume == Token::default() { 0 } else { self.resume(id, &resume) };
                    if resumed == 0 {
                        self.set_place(id, Place::Lobby);
                    }
                    self.send(id, &ServerMsg::Welcome { features: FEATURES, resumed });
                }
            }
            ClientMsg::Ping(t) => self.send(id, &ServerMsg::Pong(t)),
            ClientMsg::Queue { .. } | ClientMsg::Room { .. } if *place == Place::Lobby && self.draining => {
                self.refuse(id, Refusal::Draining, DRAINING.into());
            }
            ClientMsg::Queue { mode } if *place == Place::Lobby => {
                if mode != 0 {
                    self.send(id, &ServerMsg::Notice(format!("This server has no mode {mode} yet.")));
                    return;
                }
                match self.queue.take() {
                    Some(other) if other != id => self.start_match([other, id], Rules::shared_standard(), Vec::new()),
                    _ => {
                        self.queue = Some(id);
                        self.set_place(id, Place::Waiting);
                        self.send(id, &ServerMsg::Waiting { room: Text::default() });
                    }
                }
            }
            ClientMsg::Room { code, rules } if *place == Place::Lobby => self.on_room(id, code, rules),
            // A player can still have these in flight when an opponent leaves and sends them
            // back to the lobby, so outside a match they're ignored rather than punished.
            ClientMsg::Input(m) if *place != Place::New => {
                if let Some(mid) = playing {
                    self.on_input(mid, id, m);
                }
            }
            ClientMsg::Rematch if *place != Place::New => {
                if let Some(mid) = playing {
                    self.on_rematch(mid, id);
                }
            }
            // Anything else is out of order: a real client never does it.
            _ => self.drop_conn(id),
        }
    }

    fn on_room(&mut self, id: u64, code: Text<{ crate::protocol::MAX_ROOM }>, bytes: Vec<u8>) {
        let key = code.to_string();
        if let Some(room) = self.rooms.get(&key) {
            if room.host == id {
                return;
            }
            // The host's rules are the room's; whoever joins only brings themselves.
            let custom = !room.bytes.is_empty();
            let can = self.conns.get(&id).is_some_and(|c| c.features & features::CUSTOM_RULES != 0);
            if custom && !can {
                self.send(id, &ServerMsg::Notice("That room plays custom rules, which this game can't. Please update.".into()));
                return;
            }
            let room = self.rooms.remove(&key).unwrap();
            self.start_match([room.host, id], room.rules, room.bytes);
            return;
        }
        let rules = if bytes.is_empty() {
            Rules::shared_standard()
        } else {
            match Rules::decode(&bytes) {
                Some(r) if r == *Rules::shared_standard() => Rules::shared_standard(),
                Some(r) => Arc::new(r),
                None => {
                    self.send(id, &ServerMsg::Notice("Those rules can't be played: they're damaged or out of range.".into()));
                    return;
                }
            }
        };
        let bytes = if Arc::ptr_eq(&rules, &Rules::shared_standard()) { Vec::new() } else { bytes };
        self.rooms.insert(key.clone(), Room { host: id, rules, bytes });
        self.set_place(id, Place::Waiting);
        self.send(id, &ServerMsg::Waiting { room: code });
    }

    fn set_place(&mut self, id: u64, place: Place) {
        if let Some(c) = self.conns.get_mut(&id) {
            if c.place != place {
                c.placed = Instant::now();
            }
            c.place = place;
        }
    }

    fn seat_of(&self, id: u64) -> Seat {
        match self.conns.get(&id) {
            Some(c) => Seat { name: c.name.clone(), addr: c.addr.to_string(), platform: c.platform.clone() },
            None => Seat { name: String::new(), addr: String::new(), platform: String::new() },
        }
    }

    fn start_match(&mut self, conns: [u64; 2], rules: Arc<Rules>, rules_bytes: Vec<u8>) {
        let match_id = self.next_match;
        self.next_match += 1;
        let seed = new_seed();
        let seats = conns.map(|id| self.seat_of(id));
        let names = [seats[0].name.clone(), seats[1].name.clone()];
        let mut infos: List<SeatInfo, { crate::protocol::MAX_SEATS }> = List::default();
        for (k, s) in seats.iter().enumerate() {
            infos.push(SeatInfo { name: Text::new(&s.name), team: k as u8, platform: Text::new(&s.platform) });
        }
        let referee = Referee::with_rules(seed, rules.clone());
        self.matches.insert(
            match_id,
            Match {
                conns,
                rules,
                rules_bytes: rules_bytes.clone(),
                names: names.clone(),
                seed,
                referee,
                started: Instant::now(),
                rematch: [false; 2],
                announced: false,
                tokens: [new_token(), new_token()],
                away: [None; 2],
            },
        );
        println!("match {match_id} start seed={seed} {:?} vs {:?}", names[0], names[1]);
        if let Some(store) = &self.store {
            store.write(Op::Started { id: match_id, seed, seats });
        }
        let tokens = self.matches[&match_id].tokens;
        for (seat, id) in conns.into_iter().enumerate() {
            self.set_place(id, Place::Playing(match_id));
            self.send(id, &ServerMsg::Start { match_id, seed, seat: seat as u8, rules: rules_bytes.clone(), seats: infos, resume: tokens[seat] });
        }
    }

    /// A hello with a token: give that seat to this connection, if its match is still being
    /// played. A connection the server still thinks holds the seat (a phone that changed
    /// networks leaves one half-open) is let go. The match id, or 0.
    fn resume(&mut self, id: u64, token: &Token) -> u64 {
        let found = self.matches.iter().find_map(|(mid, m)| {
            let seat = m.tokens.iter().position(|t| t == token)?;
            (!m.announced).then_some((*mid, seat))
        });
        let Some((mid, seat)) = found else { return 0 };
        let game = self.matches.get_mut(&mid).unwrap();
        let old = std::mem::replace(&mut game.conns[seat], id);
        let other = game.conns[1 - seat];
        let was_away = game.away[seat].take().is_some();
        if old != id {
            self.forget(old);
        }
        self.set_place(id, Place::Playing(mid));
        println!("match {mid} seat {seat} resumed{}", if was_away { "" } else { ", replacing its old connection" });
        self.send(other, &ServerMsg::Away { seat: seat as u8, away: false });
        mid
    }

    fn on_input(&mut self, mid: u64, id: u64, mut m: InputMsg) {
        let Some(game) = self.matches.get_mut(&mid) else { return };
        let seat = if game.conns[0] == id { 0 } else { 1 };
        let other = game.conns[1 - seat];
        let now = ticks_since(game.started);
        // Checked first, so a message that breaks the rules never reaches the other player.
        let fine = game.referee.input(seat, &m, now);
        if fine {
            m.seat = seat as u8;
            self.send(other, &ServerMsg::Input(m));
        }
        self.announce_if_over(mid);
    }

    fn announce_if_over(&mut self, mid: u64) {
        let Some(game) = self.matches.get_mut(&mid) else { return };
        let Some(outcome) = game.referee.outcome() else { return };
        if game.announced {
            return;
        }
        game.announced = true;
        let conns = game.conns;
        let late = game.referee.latest_input;
        let replay = game.referee.replay();
        println!(
            "match {mid} end winner={} reason={} tick={} latest_input_ticks={late:?}",
            outcome.winner,
            name_of(outcome.reason),
            outcome.tick
        );
        let Outcome { winner, reason, tick } = outcome;
        let away = game.away.map(|a| a.is_some());
        for id in conns {
            self.send(id, &ServerMsg::Result { winner: if winner == 2 { 0 } else { winner }, draw: winner == 2, reason, tick });
        }
        // Nobody to ask for a rematch: whoever is still here goes back to the lobby.
        if away.contains(&true) {
            self.matches.remove(&mid);
            for seat in 0..2 {
                if !away[seat] {
                    self.send(conns[seat], &ServerMsg::Left { seat: 1 - seat as u8 });
                    self.set_place(conns[seat], Place::Lobby);
                }
            }
        }
        let mut saved = None;
        if let (Some(dir), Some(replay)) = (self.config.replay_dir.clone(), replay) {
            let file = format!("{mid}-{}.fbgr", replay.seed);
            let path = dir.join(&file);
            saved = Some(file);
            tokio::task::spawn_blocking(move || {
                if let Err(e) = std::fs::write(&path, replay.encode()) {
                    eprintln!("can't save {}: {e}", path.display());
                }
            });
        }
        if let Some(store) = &self.store {
            store.write(Op::Ended { id: mid, winner, reason: name_of(reason), tick, late, replay: saved });
        }
    }

    fn on_rematch(&mut self, mid: u64, id: u64) {
        let Some(game) = self.matches.get_mut(&mid) else { return };
        if !game.announced {
            return;
        }
        if self.draining {
            self.send(id, &ServerMsg::Notice("The server is about to restart, so no rematch this time.".into()));
            return;
        }
        let seat = if game.conns[0] == id { 0 } else { 1 };
        game.rematch[seat] = true;
        if game.rematch == [true, true] {
            let (conns, rules, bytes) = (game.conns, game.rules.clone(), game.rules_bytes.clone());
            self.matches.remove(&mid);
            self.start_match(conns, rules, bytes);
        }
    }

    fn on_clock(&mut self) {
        let mids: Vec<u64> = self.matches.keys().copied().collect();
        for mid in mids {
            if let Some(game) = self.matches.get_mut(&mid) {
                let now = ticks_since(game.started);
                game.referee.check_clock(now);
            }
            self.announce_if_over(mid);
        }
        let silent: Vec<u64> = self
            .conns
            .iter()
            .filter(|(_, c)| c.place == Place::New && c.opened.elapsed() > HELLO_LIMIT)
            .map(|(id, _)| *id)
            .collect();
        for id in silent {
            self.drop_conn(id);
        }
        // While draining, a finished match is only waiting for rematches that won't come.
        if self.draining {
            let finished: Vec<u64> = self.matches.iter().filter(|(_, m)| m.announced).map(|(id, _)| *id).collect();
            for mid in finished {
                if let Some(game) = self.matches.remove(&mid) {
                    for id in game.conns {
                        self.set_place(id, Place::Lobby);
                    }
                }
            }
        }
    }

    fn on_sample(&mut self) {
        let Some(store) = &self.store else { return };
        let playing = self.conns.values().filter(|c| matches!(c.place, Place::Playing(_))).count();
        let waiting = self.conns.values().filter(|c| c.place == Place::Waiting).count();
        store.write(Op::Sample { online: self.conns.len(), playing, waiting });
    }

    /// Removes a connection without telling it anything.
    fn forget(&mut self, id: u64) {
        self.conns.remove(&id);
    }

    fn drop_conn(&mut self, id: u64) {
        let Some(conn) = self.conns.remove(&id) else { return };
        match conn.place {
            Place::Waiting => {
                if self.queue == Some(id) {
                    self.queue = None;
                }
                self.rooms.retain(|_, r| r.host != id);
            }
            Place::Playing(mid) => {
                let held = conn.features & features::RESUME != 0 && self.matches.get(&mid).is_some_and(|m| !m.announced);
                if held {
                    self.hold_seat(mid, id);
                } else {
                    self.leave_match(mid, id);
                }
            }
            _ => {}
        }
    }

    /// The match goes on without them for now: it waits for their inputs as it would for a
    /// slow connection, and the referee ends it if they don't come back in time.
    fn hold_seat(&mut self, mid: u64, id: u64) {
        let Some(game) = self.matches.get_mut(&mid) else { return };
        let seat = if game.conns[0] == id { 0 } else { 1 };
        game.away[seat] = Some(Instant::now());
        let other = game.conns[1 - seat];
        println!("match {mid} seat {seat} dropped; holding it");
        self.send(other, &ServerMsg::Away { seat: seat as u8, away: true });
    }

    fn leave_match(&mut self, mid: u64, id: u64) {
        let Some(game) = self.matches.get_mut(&mid) else { return };
        let seat = if game.conns[0] == id { 0 } else { 1 };
        let other = game.conns[1 - seat];
        game.referee.forfeit(seat, EndReason::Left);
        self.announce_if_over(mid);
        self.matches.remove(&mid);
        self.send(other, &ServerMsg::Left { seat: seat as u8 });
        // They stay connected, and can look for another game.
        self.set_place(other, Place::Lobby);
    }

    // The admin console.

    fn on_admin(&mut self, cmd: AdminCmd) {
        match cmd {
            AdminCmd::Snapshot(reply) => {
                let _ = reply.send(self.snapshot());
            }
            AdminCmd::Watch(mid, reply) => {
                let _ = reply.send(self.watch(mid));
            }
            AdminCmd::Act(action, reply) => {
                let what = format!("{action:?}");
                let result = self.act(action);
                if let (Some(store), Ok(_)) = (&self.store, &result) {
                    store.write(Op::Audit(what.clone()));
                }
                println!("admin: {what} -> {result:?}");
                let _ = reply.send(result);
            }
        }
    }

    fn act(&mut self, action: Action) -> Result<String, String> {
        match action {
            Action::Kick(id) => {
                if !self.conns.contains_key(&id) {
                    return Err(format!("no connection {id}"));
                }
                self.send(id, &ServerMsg::Notice("You were removed from the server.".into()));
                self.drop_conn(id);
                Ok(format!("kicked {id}"))
            }
            Action::End(mid) => {
                let Some(game) = self.matches.get_mut(&mid) else { return Err(format!("no match {mid}")) };
                if game.announced {
                    return Err(format!("match {mid} is already over"));
                }
                game.referee.end();
                self.announce_if_over(mid);
                Ok(format!("ended match {mid} as a draw"))
            }
            Action::Notice(text) => {
                let text = text.trim().to_owned();
                if text.is_empty() {
                    return Err("nothing to say".into());
                }
                let ids: Vec<u64> = self.conns.iter().filter(|(_, c)| c.place != Place::New).map(|(id, _)| *id).collect();
                let n = ids.len();
                for id in ids {
                    self.send(id, &ServerMsg::Notice(text.clone()));
                }
                Ok(format!("told {n} players"))
            }
            Action::Drain { on, exit } => {
                self.draining = on;
                self.exit_when_drained = on && exit;
                if !on {
                    return Ok("taking new matches again".into());
                }
                // Whoever is waiting won't get a game now.
                let waiting: Vec<u64> = self.conns.iter().filter(|(_, c)| c.place == Place::Waiting).map(|(id, _)| *id).collect();
                for id in waiting {
                    self.drop_waiting(id);
                    self.refuse(id, Refusal::Draining, DRAINING.into());
                }
                let playing: Vec<u64> = self.conns.iter().filter(|(_, c)| matches!(c.place, Place::Playing(_))).map(|(id, _)| *id).collect();
                for id in playing {
                    self.send(id, &ServerMsg::Notice("The server will restart after this game.".into()));
                }
                let left = self.matches.values().filter(|m| !m.announced).count();
                Ok(format!("draining, {left} matches still playing{}", if exit { ", then stopping" } else { "" }))
            }
            Action::Ban { addr, note } => {
                let ip: IpAddr = addr.trim().parse().map_err(|_| format!("{addr} isn't an address"))?;
                let addr = ip.to_string();
                self.bans.insert(addr.clone());
                if let Some(store) = &self.store {
                    store.write(Op::Ban { addr: addr.clone(), note });
                }
                let theirs: Vec<u64> = self.conns.iter().filter(|(_, c)| c.addr == ip).map(|(id, _)| *id).collect();
                let n = theirs.len();
                for id in theirs {
                    self.send(id, &ServerMsg::Notice(BANNED.into()));
                    self.drop_conn(id);
                }
                Ok(format!("banned {addr}, closed {n} connections"))
            }
            Action::Unban(addr) => {
                let addr = addr.trim().to_owned();
                if !self.bans.remove(&addr) {
                    return Err(format!("{addr} isn't banned"));
                }
                if let Some(store) = &self.store {
                    store.write(Op::Unban { addr: addr.clone() });
                }
                Ok(format!("unbanned {addr}"))
            }
        }
    }

    /// Takes a waiting player out of the queue or their room, leaving the connection.
    fn drop_waiting(&mut self, id: u64) {
        if self.queue == Some(id) {
            self.queue = None;
        }
        self.rooms.retain(|_, r| r.host != id);
    }

    fn snapshot(&self) -> Snapshot {
        let room_of: HashMap<u64, &str> = self.rooms.iter().map(|(code, r)| (r.host, code.as_str())).collect();
        let mut conns: Vec<ConnInfo> = self
            .conns
            .iter()
            .map(|(id, c)| ConnInfo {
                id: *id,
                name: c.name.clone(),
                addr: c.addr.to_string(),
                platform: c.platform.clone(),
                place: match c.place {
                    Place::New => "new".into(),
                    Place::Lobby => "lobby".into(),
                    Place::Waiting => match room_of.get(id) {
                        Some(code) => format!("room {code}"),
                        None => "queue".into(),
                    },
                    Place::Playing(m) => format!("match {m}"),
                },
                rtt_ms: c.rtt_ms,
                age_s: c.opened.elapsed().as_secs(),
                here_s: c.placed.elapsed().as_secs(),
            })
            .collect();
        conns.sort_by_key(|c| c.id);
        let mut matches: Vec<MatchInfo> = self
            .matches
            .iter()
            .map(|(id, m)| MatchInfo {
                id: *id,
                seed: m.seed,
                conns: m.conns,
                names: m.names.clone(),
                age_s: m.started.elapsed().as_secs(),
                clock: ticks_since(m.started),
                refereed: m.referee.tick(),
                frontiers: m.referee.frontiers(),
                late: m.referee.latest_input,
                over: m.referee.outcome().map(|o| describe(&o)),
                away: m.away.map(|a| a.is_some()),
            })
            .collect();
        matches.sort_by_key(|m| m.id);
        Snapshot {
            version: env!("CARGO_PKG_VERSION"),
            protocol: PROTOCOL,
            rules: RULES_VERSION,
            uptime_s: self.born.elapsed().as_secs(),
            draining: self.draining,
            exit_when_drained: self.exit_when_drained,
            conns,
            matches,
        }
    }

    fn watch(&self, mid: u64) -> Option<Watch> {
        let m = self.matches.get(&mid)?;
        let state = m.referee.state();
        let boards = state
            .boards
            .iter()
            .map(|b| BoardView {
                cells: b.color[BUF * W..].to_vec(),
                next_row: b.next_row.to_vec(),
                cursor: [b.cursor_x, b.cursor_y - BUF as i64],
                score: b.score,
                chain: b.chain_n,
                health: b.health,
                incoming: b.gar_q.len(),
                lost: b.lost,
            })
            .collect();
        Some(Watch { id: mid, tick: state.tick, names: m.names.clone(), over: m.referee.outcome().map(|o| describe(&o)), boards })
    }
}

fn ticks_since(started: Instant) -> i64 {
    (started.elapsed().as_micros() as i64) * i64::from(TICK_HZ) / 1_000_000
}
