//! How many matches a server holds, and what relaying adds to a player's input delay. Plays a
//! recorded CPU game on repeat in real time, as many times over as asked, at 60 messages a second.
//!   cargo run --release -p fbg-server --bin load_test -- ws://127.0.0.1:47110 MATCHES SECONDS REPLAY

use fbg_server::protocol::{ClientMsg, InputMsg, List, ServerMsg, PROTOCOL};
use fbg_sim::consts::{RULES_VERSION, TICK_HZ};
use fbg_sim::Replay;
use futures_util::{SinkExt, StreamExt};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio_tungstenite::tungstenite::Message;

const TICKS_PER_MESSAGE: i64 = TICK_HZ as i64 / 60;

async fn play(url: String, room: String, seat: usize, replay: Arc<Replay>, seconds: u64, clock: Instant, delays: Arc<Mutex<Vec<u64>>>) {
    let Ok((socket, _)) = tokio_tungstenite::connect_async(&url).await else {
        eprintln!("can't connect");
        return;
    };
    let (mut tx, mut rx) = socket.split();
    let hello = ClientMsg::Hello { protocol: PROTOCOL, engine: RULES_VERSION as u32, tick_hz: TICK_HZ as u32, name: "load".into(), platform: "load_test".into(), features: 0, resume: Default::default() };
    let _ = tx.send(Message::binary(hello.encode())).await;
    let _ = tx.send(Message::binary(ClientMsg::Room { code: room.as_str().into(), rules: vec![], teams: vec![] }.encode())).await;
    // Waits for the start, then listens while it plays.
    loop {
        let Some(Ok(Message::Binary(b))) = rx.next().await else { return };
        if matches!(ServerMsg::read(&b), Some(ServerMsg::Start { .. })) {
            break;
        }
    }
    let listen = tokio::spawn(async move {
        let mut seen = Vec::new();
        while let Some(Ok(Message::Binary(b))) = rx.next().await {
            // The sender's clock travels in `advantage`: this tool's clients share one.
            if let Some(ServerMsg::Input(m)) = ServerMsg::read(&b) {
                seen.push((clock.elapsed().as_micros() as i64 - m.advantage).max(0) as u64);
            }
        }
        seen
    });
    let mut next = 0;
    let mut pace = tokio::time::interval(Duration::from_micros(1_000_000 / 60));
    let end = Instant::now() + Duration::from_secs(seconds);
    let mut tick = 0i64;
    while Instant::now() < end && (tick as u64) + (TICKS_PER_MESSAGE as u64) < replay.end_tick {
        pace.tick().await;
        tick += TICKS_PER_MESSAGE;
        let mut changes = List::default();
        while let Some(e) = replay.inputs[seat].get(next).filter(|e| (e.tick as i64) < tick) {
            changes.push((e.tick as i64, e.mask as i32));
            next += 1;
        }
        let m = InputMsg { frontier: tick - 1, ack: -1, tick, advantage: clock.elapsed().as_micros() as i64, changes, ..Default::default() };
        if tx.send(Message::binary(ClientMsg::Input(m).encode())).await.is_err() {
            break;
        }
    }
    let _ = tx.close().await;
    if let Ok(seen) = listen.await {
        delays.lock().unwrap().extend(seen);
    }
}

#[tokio::main]
async fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (url, matches, seconds, path) = (a[1].clone(), a[2].parse::<usize>().unwrap(), a[3].parse::<u64>().unwrap(), &a[4]);
    let replay = Arc::new(Replay::decode(&std::fs::read(path).unwrap()).unwrap());
    let delays = Arc::new(Mutex::new(Vec::new()));
    let clock = Instant::now();
    let run = rand_tag();
    let mut players = Vec::new();
    for m in 0..matches {
        for seat in 0..2 {
            players.push(tokio::spawn(play(url.clone(), format!("L{run}X{m}"), seat, replay.clone(), seconds, clock, delays.clone())));
        }
        // Not everyone at once: a real server doesn't see that either.
        tokio::time::sleep(Duration::from_millis(2)).await;
    }
    for p in players {
        let _ = p.await;
    }
    let mut d = delays.lock().unwrap().clone();
    d.sort_unstable();
    if d.is_empty() {
        println!("no messages arrived");
        return;
    }
    let at = |q: f64| d[((d.len() - 1) as f64 * q) as usize] as f64 / 1000.0;
    println!("{matches} matches: {} messages relayed, delay p50 {:.2} ms, p99 {:.2} ms, p99.9 {:.2} ms, max {:.2} ms", d.len(), at(0.5), at(0.99), at(0.999), at(1.0));
}

fn rand_tag() -> u32 {
    std::process::id() % 100_000
}
