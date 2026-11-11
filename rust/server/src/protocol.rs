//! The messages between game and server, as bytes. Laid out in `docs/server-protocol.md`, and
//! `net/server_link.gd` is the other end. `decode` treats its input as hostile: anything a
//! client sends comes back as a message or None, never a panic or an oversized allocation.

pub const PROTOCOL: u16 = 2;
pub const MAX_CHANGES: usize = 256;
pub const MAX_CHECKS: usize = 16;
pub const MAX_ROOM: usize = 16;
pub const MAX_REASON: usize = 200;
pub const MAX_NAME: usize = 24; // bytes of UTF-8
pub const MAX_PLATFORM: usize = 16;

/// One player's input so far. The same shape travels both ways through the server.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct InputMsg {
    pub frontier: i64, // inputs are final up to and including this tick
    pub ack: i64,      // newest change of the other player's this sender has seen
    pub tick: i64,     // the sender's clock
    pub advantage: i64,
    pub changes: Vec<(i64, i32)>, // (tick, mask)
    pub checks: Vec<(i64, i64)>,  // (tick, state hash), final
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub enum ClientMsg {
    Hello { protocol: u16, rules: u16, tick_hz: u16, name: String, platform: String },
    Queue,
    Room(String),
    Input(InputMsg),
    Rematch,
    Ping(u64),
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u8)]
pub enum EndReason {
    Played = 0,
    Left = 1,
    Stalled = 2,
    WrongState = 3,
    BadInput = 4,
    TooLong = 5,
    Ended = 6, // by whoever runs the server
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub enum ServerMsg {
    Welcome,
    Refused(String),
    Waiting,
    Start { match_id: u64, seed: i64, seat: u8, opponent: String },
    Input(InputMsg),
    Result { winner: u8, reason: EndReason, tick: i64 },
    Pong(u64),
    OpponentLeft,
    Notice(String), // from whoever runs the server, for the player to read
}

struct Reader<'a> {
    b: &'a [u8],
}

impl Reader<'_> {
    fn take(&mut self, n: usize) -> Option<&[u8]> {
        if self.b.len() < n {
            return None;
        }
        let (head, rest) = self.b.split_at(n);
        self.b = rest;
        Some(head)
    }
    fn u8(&mut self) -> Option<u8> {
        self.take(1).map(|v| v[0])
    }
    fn u16(&mut self) -> Option<u16> {
        self.take(2).map(|v| u16::from_le_bytes([v[0], v[1]]))
    }
    fn i32(&mut self) -> Option<i32> {
        self.take(4).and_then(|v| v.try_into().ok()).map(i32::from_le_bytes)
    }
    fn i64(&mut self) -> Option<i64> {
        self.take(8).and_then(|v| v.try_into().ok()).map(i64::from_le_bytes)
    }
    /// A length byte, then that many bytes of text. None if it's longer than `max`.
    fn text(&mut self, max: usize) -> Option<&str> {
        let n = self.u8()? as usize;
        if n > max {
            return None;
        }
        std::str::from_utf8(self.take(n)?).ok()
    }
    fn done(&self) -> bool {
        self.b.is_empty()
    }
}

/// A length byte and the text, cut to `max` bytes without splitting a character.
fn write_text(out: &mut Vec<u8>, text: &str, max: usize) {
    let mut end = text.len().min(max);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    out.push(end as u8);
    out.extend_from_slice(&text.as_bytes()[..end]);
}

/// A name as the server keeps it: no control characters, no padding, never empty.
pub fn clean_name(name: &str) -> String {
    let kept: String = name.chars().filter(|c| !c.is_control()).collect();
    let kept = kept.trim();
    if kept.is_empty() { "Player".into() } else { kept.into() }
}

fn read_input(r: &mut Reader) -> Option<InputMsg> {
    let (frontier, ack, tick, advantage) = (r.i64()?, r.i64()?, r.i64()?, r.i64()?);
    let n = r.u16()? as usize;
    if n > MAX_CHANGES {
        return None;
    }
    let mut changes = Vec::with_capacity(n.min(r.b.len() / 12));
    for _ in 0..n {
        changes.push((r.i64()?, r.i32()?));
    }
    let n = r.u8()? as usize;
    if n > MAX_CHECKS {
        return None;
    }
    let mut checks = Vec::with_capacity(n);
    for _ in 0..n {
        checks.push((r.i64()?, r.i64()?));
    }
    Some(InputMsg { frontier, ack, tick, advantage, changes, checks })
}

fn write_input(out: &mut Vec<u8>, m: &InputMsg) {
    for v in [m.frontier, m.ack, m.tick, m.advantage] {
        out.extend_from_slice(&v.to_le_bytes());
    }
    out.extend_from_slice(&(m.changes.len() as u16).to_le_bytes());
    for (t, mask) in &m.changes {
        out.extend_from_slice(&t.to_le_bytes());
        out.extend_from_slice(&mask.to_le_bytes());
    }
    out.push(m.checks.len() as u8);
    for (t, h) in &m.checks {
        out.extend_from_slice(&t.to_le_bytes());
        out.extend_from_slice(&h.to_le_bytes());
    }
}

impl ClientMsg {
    pub fn decode(bytes: &[u8]) -> Option<ClientMsg> {
        let mut r = Reader { b: bytes };
        let msg = match r.u8()? {
            1 => {
                let (protocol, rules, tick_hz) = (r.u16()?, r.u16()?, r.u16()?);
                // Older games stop here, and still deserve to be told to update.
                if r.done() {
                    return Some(ClientMsg::Hello { protocol, rules, tick_hz, name: String::new(), platform: String::new() });
                }
                let name = r.text(MAX_NAME)?.to_owned();
                let platform = r.text(MAX_PLATFORM)?;
                if !platform.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'.' || c == b'_') {
                    return None;
                }
                ClientMsg::Hello { protocol, rules, tick_hz, name, platform: platform.to_owned() }
            }
            2 => ClientMsg::Queue,
            3 => {
                let n = r.u8()? as usize;
                if n == 0 || n > MAX_ROOM {
                    return None;
                }
                let code = std::str::from_utf8(r.take(n)?).ok()?;
                if !code.bytes().all(|c| c.is_ascii_alphanumeric()) {
                    return None;
                }
                ClientMsg::Room(code.to_ascii_uppercase())
            }
            4 => ClientMsg::Input(read_input(&mut r)?),
            5 => ClientMsg::Rematch,
            6 => ClientMsg::Ping(r.i64()? as u64),
            _ => return None,
        };
        r.done().then_some(msg)
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        match self {
            ClientMsg::Hello { protocol, rules, tick_hz, name, platform } => {
                out.push(1);
                for v in [protocol, rules, tick_hz] {
                    out.extend_from_slice(&v.to_le_bytes());
                }
                write_text(&mut out, name, MAX_NAME);
                write_text(&mut out, platform, MAX_PLATFORM);
            }
            ClientMsg::Queue => out.push(2),
            ClientMsg::Room(code) => {
                out.push(3);
                out.push(code.len() as u8);
                out.extend_from_slice(code.as_bytes());
            }
            ClientMsg::Input(m) => {
                out.push(4);
                write_input(&mut out, m);
            }
            ClientMsg::Rematch => out.push(5),
            ClientMsg::Ping(t) => {
                out.push(6);
                out.extend_from_slice(&t.to_le_bytes());
            }
        }
        out
    }
}

impl ServerMsg {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        match self {
            ServerMsg::Welcome => out.push(64),
            ServerMsg::Refused(why) => {
                out.push(65);
                write_text(&mut out, why, MAX_REASON);
            }
            ServerMsg::Waiting => out.push(66),
            ServerMsg::Start { match_id, seed, seat, opponent } => {
                out.push(67);
                out.extend_from_slice(&match_id.to_le_bytes());
                out.extend_from_slice(&seed.to_le_bytes());
                out.push(*seat);
                write_text(&mut out, opponent, MAX_NAME);
            }
            ServerMsg::Input(m) => {
                out.push(68);
                write_input(&mut out, m);
            }
            ServerMsg::Result { winner, reason, tick } => {
                out.push(69);
                out.push(*winner);
                out.push(*reason as u8);
                out.extend_from_slice(&tick.to_le_bytes());
            }
            ServerMsg::Pong(t) => {
                out.push(70);
                out.extend_from_slice(&t.to_le_bytes());
            }
            ServerMsg::OpponentLeft => out.push(71),
            ServerMsg::Notice(text) => {
                out.push(72);
                write_text(&mut out, text, MAX_REASON);
            }
        }
        out
    }

    /// For tests and tools. Clients don't get to send these.
    pub fn decode(bytes: &[u8]) -> Option<ServerMsg> {
        let mut r = Reader { b: bytes };
        let msg = match r.u8()? {
            64 => ServerMsg::Welcome,
            65 => {
                let n = r.u8()? as usize;
                ServerMsg::Refused(String::from_utf8_lossy(r.take(n)?).into_owned())
            }
            66 => ServerMsg::Waiting,
            67 => ServerMsg::Start { match_id: r.i64()? as u64, seed: r.i64()?, seat: r.u8()?, opponent: r.text(MAX_NAME)?.to_owned() },
            68 => ServerMsg::Input(read_input(&mut r)?),
            69 => {
                let winner = r.u8()?;
                let reason = match r.u8()? {
                    0 => EndReason::Played,
                    1 => EndReason::Left,
                    2 => EndReason::Stalled,
                    3 => EndReason::WrongState,
                    4 => EndReason::BadInput,
                    5 => EndReason::TooLong,
                    6 => EndReason::Ended,
                    _ => return None,
                };
                ServerMsg::Result { winner, reason, tick: r.i64()? }
            }
            70 => ServerMsg::Pong(r.i64()? as u64),
            71 => ServerMsg::OpponentLeft,
            72 => ServerMsg::Notice(r.text(MAX_REASON)?.to_owned()),
            _ => return None,
        };
        r.done().then_some(msg)
    }
}
