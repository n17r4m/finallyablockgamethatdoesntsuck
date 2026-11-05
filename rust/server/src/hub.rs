//! Connections, the lobby and running matches. One task owns all of it and everything else
//! talks to that task, so there are no locks and a match can't be seen half-updated.

use crate::protocol::{ClientMsg, EndReason, InputMsg, ServerMsg, MAX_CHANGES, MAX_CHECKS, PROTOCOL};
use crate::referee::{Outcome, Referee};
use fbg_sim::consts::{RULES_VERSION, TICK_HZ};
use futures_util::{SinkExt, StreamExt};
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{Duration, Instant};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::Message;

const HELLO_LIMIT: Duration = Duration::from_secs(5);
const CLOCK_EVERY: Duration = Duration::from_millis(250);
const MAX_MESSAGES_PER_SECOND: u32 = 1000; // far above any display rate
const OUTGOING_QUEUE: usize = 512;
const MAX_FRAME: usize = 64 + MAX_CHANGES * 12 + MAX_CHECKS * 16;

#[derive(Clone)]
pub struct Config {
    pub max_connections: usize,
    pub replay_dir: Option<PathBuf>,
}

impl Default for Config {
    fn default() -> Self {
        Config { max_connections: 4096, replay_dir: None }
    }
}

enum Event {
    Opened(u64, mpsc::Sender<Vec<u8>>),
    Message(u64, ClientMsg),
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
    opened: Instant,
    window: Instant,
    messages: u32,
}

struct Match {
    conns: [u64; 2],
    referee: Referee,
    started: Instant,
    rematch: [bool; 2],
    announced: bool,
}

struct Hub {
    conns: HashMap<u64, Conn>,
    matches: HashMap<u64, Match>,
    queue: Option<u64>,
    rooms: HashMap<String, u64>,
    next_match: u64,
    config: Config,
}

/// Runs the server on a listener that's already bound, until the process ends.
pub async fn serve(listener: TcpListener, config: Config) {
    let (events, mut inbox) = mpsc::channel::<Event>(4096);
    let accepting = tokio::spawn(accept_loop(listener, events));
    let mut hub = Hub { conns: HashMap::new(), matches: HashMap::new(), queue: None, rooms: HashMap::new(), next_match: 1, config };
    let mut clock = tokio::time::interval(CLOCK_EVERY);
    loop {
        tokio::select! {
            event = inbox.recv() => match event {
                Some(event) => hub.handle(event),
                None => break,
            },
            _ = clock.tick() => hub.on_clock(),
        }
    }
    accepting.abort();
}

async fn accept_loop(listener: TcpListener, events: mpsc::Sender<Event>) {
    let mut next_id = 1u64;
    loop {
        let Ok((stream, _)) = listener.accept().await else {
            tokio::time::sleep(Duration::from_millis(50)).await;
            continue;
        };
        let id = next_id;
        next_id += 1;
        tokio::spawn(run_connection(id, stream, events.clone()));
    }
}

/// One player's socket. Rollback needs inputs now, not a fuller packet later: hence no Nagle.
async fn run_connection(id: u64, stream: TcpStream, events: mpsc::Sender<Event>) {
    let _ = stream.set_nodelay(true);
    let config = WebSocketConfig::default().max_message_size(Some(MAX_FRAME)).max_frame_size(Some(MAX_FRAME));
    let handshake = tokio_tungstenite::accept_async_with_config(stream, Some(config));
    let Ok(Ok(socket)) = tokio::time::timeout(HELLO_LIMIT, handshake).await else {
        return;
    };
    let (mut sink, mut source) = socket.split();
    let (tx, mut rx) = mpsc::channel::<Vec<u8>>(OUTGOING_QUEUE);
    if events.send(Event::Opened(id, tx)).await.is_err() {
        return;
    }
    let writer = tokio::spawn(async move {
        while let Some(bytes) = rx.recv().await {
            if sink.send(Message::binary(bytes)).await.is_err() {
                break;
            }
        }
        let _ = sink.close().await;
    });
    while let Some(Ok(frame)) = source.next().await {
        let event = match frame {
            Message::Binary(bytes) => match ClientMsg::decode(&bytes) {
                Some(msg) => Event::Message(id, msg),
                None => Event::Junk(id),
            },
            Message::Close(_) => break,
            Message::Ping(_) | Message::Pong(_) => continue,
            _ => Event::Junk(id),
        };
        if events.send(event).await.is_err() {
            break;
        }
    }
    let _ = events.send(Event::Closed(id)).await;
    writer.abort();
}

fn new_seed() -> i64 {
    let mut bytes = [0u8; 4];
    // With no OS randomness the match can still be played; it just has a guessable seed.
    let _ = getrandom::fill(&mut bytes);
    i64::from(u32::from_le_bytes(bytes))
}

fn name_of(reason: EndReason) -> &'static str {
    match reason {
        EndReason::Played => "played",
        EndReason::Left => "left",
        EndReason::Stalled => "stalled",
        EndReason::WrongState => "wrong_state",
        EndReason::BadInput => "bad_input",
        EndReason::TooLong => "too_long",
    }
}

impl Hub {
    fn handle(&mut self, event: Event) {
        match event {
            Event::Opened(id, tx) => {
                if self.conns.len() >= self.config.max_connections {
                    let _ = tx.try_send(ServerMsg::Refused("The server is full".into()).encode());
                    return; // dropping tx ends the writer, which closes the socket
                }
                let now = Instant::now();
                self.conns.insert(id, Conn { tx, place: Place::New, opened: now, window: now, messages: 0 });
            }
            Event::Message(id, msg) => {
                if self.over_rate(id) {
                    self.drop_conn(id);
                } else {
                    self.on_message(id, msg);
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

    fn refuse(&mut self, id: u64, why: String) {
        self.send(id, &ServerMsg::Refused(why));
        self.forget(id);
    }

    fn on_message(&mut self, id: u64, msg: ClientMsg) {
        let Some(place) = self.conns.get(&id).map(|c| &c.place) else { return };
        let playing = if let Place::Playing(m) = place { Some(*m) } else { None };
        match msg {
            ClientMsg::Hello { protocol, rules, tick_hz } if *place == Place::New => {
                if protocol != PROTOCOL {
                    self.refuse(id, format!("This game speaks protocol {protocol}, the server {PROTOCOL}. Please update."));
                } else if rules != RULES_VERSION || tick_hz != TICK_HZ {
                    self.refuse(id, format!("This game has rules {rules}, the server {RULES_VERSION}. Please update."));
                } else {
                    self.set_place(id, Place::Lobby);
                    self.send(id, &ServerMsg::Welcome);
                }
            }
            ClientMsg::Ping(t) => self.send(id, &ServerMsg::Pong(t)),
            ClientMsg::Queue if *place == Place::Lobby => match self.queue.take() {
                Some(other) if other != id => self.start_match([other, id]),
                _ => {
                    self.queue = Some(id);
                    self.set_place(id, Place::Waiting);
                    self.send(id, &ServerMsg::Waiting);
                }
            },
            ClientMsg::Room(code) if *place == Place::Lobby => match self.rooms.remove(&code) {
                Some(other) if other != id => self.start_match([other, id]),
                _ => {
                    self.rooms.insert(code, id);
                    self.set_place(id, Place::Waiting);
                    self.send(id, &ServerMsg::Waiting);
                }
            },
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

    fn set_place(&mut self, id: u64, place: Place) {
        if let Some(c) = self.conns.get_mut(&id) {
            c.place = place;
        }
    }

    fn start_match(&mut self, conns: [u64; 2]) {
        let match_id = self.next_match;
        self.next_match += 1;
        let seed = new_seed();
        self.matches.insert(match_id, Match { conns, referee: Referee::new(seed), started: Instant::now(), rematch: [false; 2], announced: false });
        println!("match {match_id} start seed={seed}");
        for (seat, id) in conns.into_iter().enumerate() {
            self.set_place(id, Place::Playing(match_id));
            self.send(id, &ServerMsg::Start { match_id, seed, seat: seat as u8 });
        }
    }

    fn on_input(&mut self, mid: u64, id: u64, m: InputMsg) {
        let Some(game) = self.matches.get_mut(&mid) else { return };
        let seat = if game.conns[0] == id { 0 } else { 1 };
        let other = game.conns[1 - seat];
        let now = ticks_since(game.started);
        // Checked first, so a message that breaks the rules never reaches the other player.
        let fine = game.referee.input(seat, &m, now);
        if fine {
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
        for id in conns {
            self.send(id, &ServerMsg::Result { winner, reason, tick });
        }
        if let (Some(dir), Some(replay)) = (self.config.replay_dir.clone(), replay) {
            let path = dir.join(format!("{mid}-{}.fbgr", replay.seed));
            tokio::task::spawn_blocking(move || {
                if let Err(e) = std::fs::write(&path, replay.encode()) {
                    eprintln!("can't save {}: {e}", path.display());
                }
            });
        }
    }

    fn on_rematch(&mut self, mid: u64, id: u64) {
        let Some(game) = self.matches.get_mut(&mid) else { return };
        if !game.announced {
            return;
        }
        let seat = if game.conns[0] == id { 0 } else { 1 };
        game.rematch[seat] = true;
        if game.rematch == [true, true] {
            let conns = game.conns;
            self.matches.remove(&mid);
            self.start_match(conns);
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
                self.rooms.retain(|_, waiting| *waiting != id);
            }
            Place::Playing(mid) => self.leave_match(mid, id),
            _ => {}
        }
    }

    fn leave_match(&mut self, mid: u64, id: u64) {
        let Some(game) = self.matches.get_mut(&mid) else { return };
        let seat = if game.conns[0] == id { 0 } else { 1 };
        let other = game.conns[1 - seat];
        game.referee.forfeit(seat, EndReason::Left);
        self.announce_if_over(mid);
        self.matches.remove(&mid);
        self.send(other, &ServerMsg::OpponentLeft);
        // They stay connected, and can look for another game.
        self.set_place(other, Place::Lobby);
    }
}

fn ticks_since(started: Instant) -> i64 {
    (started.elapsed().as_micros() as i64) * i64::from(TICK_HZ) / 1_000_000
}
