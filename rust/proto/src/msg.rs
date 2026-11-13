//! Protocol 3: every message between a game and the match server. `docs/server-protocol.md`
//! lays them out. A frame is a message number (varint), then that message's fields.
//!
//! Growing it: add a field with a new number, or a message with a new number. Older readers
//! skip what they don't know. Change what a field means, or take one away, and that's a new
//! protocol number. `decode` treats its input as hostile: damage is an error, never a panic or
//! an allocation bigger than the frame.

use crate::wire::*;
use std::fmt;
use std::ops::{Deref, DerefMut};

pub const PROTOCOL: u32 = 3;
pub const MAX_CHANGES: usize = 256;
pub const MAX_CHECKS: usize = 16;
pub const MAX_ROOM: usize = 16;
pub const MAX_NAME: usize = 24; // bytes of UTF-8
pub const MAX_PLATFORM: usize = 16;
pub const MAX_TEXT: usize = 200;
pub const MAX_SEATS: usize = 64;
/// Bigger than the largest valid ruleset (`fbg_sim::rules::MAX_BYTES`), so any ruleset fits.
pub const MAX_RULES: usize = 1 << 17;
/// A resume token's length. All zeros: none.
pub const RESUME: usize = 16;
pub type Token = [u8; RESUME];

/// What a game or server can do beyond the protocol's core. Each side says what it has in its
/// hello or welcome; neither sends the other something it didn't say it understands.
pub mod features {
    /// Rooms played on a ruleset of the host's.
    pub const CUSTOM_RULES: u64 = 1;
    /// Gets its seat back after a dropped connection, with the token from its start.
    pub const RESUME: u64 = 2;
}

// Message numbers. Games send 1 to 15, the server 16 and up.
const HELLO: u64 = 1;
const QUEUE: u64 = 2;
const ROOM: u64 = 3;
const INPUT: u64 = 4;
const REMATCH: u64 = 5;
const PING: u64 = 6;
const WELCOME: u64 = 16;
const REFUSED: u64 = 17;
const WAITING: u64 = 18;
const START: u64 = 19;
const RELAY: u64 = 20;
const RESULT: u64 = 21;
const PONG: u64 = 22;
const LEFT: u64 = 23;
const NOTICE: u64 = 24;
const AWAY: u64 = 25;

/// Up to N items, kept in place, so reading one needs no allocation.
#[derive(Clone, Copy)]
pub struct List<T: Copy + Default, const N: usize> {
    len: usize,
    items: [T; N],
}

impl<T: Copy + Default, const N: usize> Default for List<T, N> {
    fn default() -> Self {
        List { len: 0, items: [T::default(); N] }
    }
}

impl<T: Copy + Default, const N: usize> List<T, N> {
    /// False, and nothing added, when full.
    pub fn push(&mut self, v: T) -> bool {
        if self.len == N {
            return false;
        }
        self.items[self.len] = v;
        self.len += 1;
        true
    }
    pub fn clear(&mut self) {
        self.len = 0;
    }
    /// The first N of `items`.
    pub fn of(items: &[T]) -> Self {
        let mut l = Self::default();
        for &v in items.iter().take(N) {
            l.push(v);
        }
        l
    }
}

impl<T: Copy + Default, const N: usize> Deref for List<T, N> {
    type Target = [T];
    fn deref(&self) -> &[T] {
        &self.items[..self.len]
    }
}

impl<T: Copy + Default, const N: usize> DerefMut for List<T, N> {
    fn deref_mut(&mut self) -> &mut [T] {
        &mut self.items[..self.len]
    }
}

impl<'a, T: Copy + Default, const N: usize> IntoIterator for &'a mut List<T, N> {
    type Item = &'a mut T;
    type IntoIter = std::slice::IterMut<'a, T>;
    fn into_iter(self) -> Self::IntoIter {
        self.iter_mut()
    }
}

impl<'a, T: Copy + Default, const N: usize> IntoIterator for &'a List<T, N> {
    type Item = &'a T;
    type IntoIter = std::slice::Iter<'a, T>;
    fn into_iter(self) -> Self::IntoIter {
        self.iter()
    }
}

impl<T: Copy + Default + PartialEq, const N: usize> PartialEq for List<T, N> {
    fn eq(&self, other: &Self) -> bool {
        **self == **other
    }
}
impl<T: Copy + Default + Eq, const N: usize> Eq for List<T, N> {}

impl<T: Copy + Default + fmt::Debug, const N: usize> fmt::Debug for List<T, N> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        (**self).fmt(f)
    }
}

impl<T: Copy + Default, const N: usize> From<Vec<T>> for List<T, N> {
    /// The first N items.
    fn from(v: Vec<T>) -> Self {
        Self::of(&v)
    }
}

/// Up to N bytes of UTF-8, kept in place.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Text<const N: usize> {
    len: u8,
    buf: [u8; N],
}

impl<const N: usize> Default for Text<N> {
    fn default() -> Self {
        Text { len: 0, buf: [0; N] }
    }
}

impl<const N: usize> Text<N> {
    /// `s` cut to N bytes without splitting a character.
    pub fn new(s: &str) -> Self {
        let mut end = s.len().min(N);
        while !s.is_char_boundary(end) {
            end -= 1;
        }
        let mut t = Self::default();
        t.buf[..end].copy_from_slice(&s.as_bytes()[..end]);
        t.len = end as u8;
        t
    }
    pub fn as_str(&self) -> &str {
        // Only ever filled from a &str, cut on a character boundary.
        std::str::from_utf8(&self.buf[..self.len as usize]).unwrap_or("")
    }
}

impl<const N: usize> Deref for Text<N> {
    type Target = str;
    fn deref(&self) -> &str {
        self.as_str()
    }
}

impl<const N: usize> fmt::Debug for Text<N> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        self.as_str().fmt(f)
    }
}

impl<const N: usize> fmt::Display for Text<N> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        self.as_str().fmt(f)
    }
}

impl<const N: usize> From<&str> for Text<N> {
    fn from(s: &str) -> Self {
        Text::new(s)
    }
}

/// One player's input so far, the same shape both ways. From the server, `seat` says whose.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct InputMsg {
    pub seat: u8,
    pub frontier: i64, // inputs are final up to and including this tick
    pub ack: i64,      // newest change of the other players' this sender has seen
    pub tick: i64,     // the sender's clock
    pub advantage: i64,
    pub changes: List<(i64, i32), MAX_CHANGES>, // (tick, mask)
    pub checks: List<(i64, i64), MAX_CHECKS>,   // (tick, state hash), final
}

/// The name a server goes by and the seat's team, as shown to the other players.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct SeatInfo {
    pub name: Text<MAX_NAME>,
    pub team: u8,
    pub platform: Text<MAX_PLATFORM>,
}

/// Inputs are kept in place (a few KB), on purpose: reading one never allocates.
#[allow(clippy::large_enum_variant)]
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum ClientMsg {
    Hello {
        protocol: u32,
        engine: u32, // fbg_sim's RULES_VERSION: which engine it plays rules on
        tick_hz: u32,
        name: Text<MAX_NAME>,
        platform: Text<MAX_PLATFORM>,
        features: u64,
        /// A start's token, to take that seat back after a dropped connection. Zeros: a new arrival.
        resume: Token,
    },
    /// Quick match. Mode 0 is standard 1v1, the only one so far.
    Queue { mode: u32 },
    /// Meet whoever else asks for this code. Whoever's first is the host, and their rules
    /// (none: standard) are the match's.
    Room { code: Text<MAX_ROOM>, rules: Vec<u8> },
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

impl EndReason {
    fn from(v: u64) -> Option<EndReason> {
        use EndReason::*;
        Some(match v {
            0 => Played,
            1 => Left,
            2 => Stalled,
            3 => WrongState,
            4 => BadInput,
            5 => TooLong,
            6 => Ended,
            _ => return None,
        })
    }
}

/// Why the server won't do what was asked. A game that doesn't know a code shows the text.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u8)]
pub enum Refusal {
    Other = 0,
    Update = 1, // a different protocol, engine or tick rate
    Draining = 2,
    Banned = 3,
    Full = 4,
    BadRules = 5,
}

impl Refusal {
    fn from(v: u64) -> Refusal {
        use Refusal::*;
        match v {
            1 => Update,
            2 => Draining,
            3 => Banned,
            4 => Full,
            5 => BadRules,
            _ => Other,
        }
    }
}

#[allow(clippy::large_enum_variant)]
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum ServerMsg {
    /// `resumed`: the match this player is back in, from the hello's token; 0 for none.
    Welcome { features: u64, resumed: u64 },
    /// The connection closes after this.
    Refused { code: Refusal, text: String },
    /// In the queue, or in a room waiting for someone with the same code.
    Waiting { room: Text<MAX_ROOM> },
    /// `resume`: this seat's token, for a hello after a dropped connection.
    Start { match_id: u64, seed: i64, seat: u8, rules: Vec<u8>, seats: List<SeatInfo, MAX_SEATS>, resume: Token },
    Input(InputMsg),
    /// `winner` is a seat, unless `draw`.
    Result { winner: u8, draw: bool, reason: EndReason, tick: i64 },
    Pong(u64),
    /// That seat's player left after the game; this player is back in the lobby.
    Left { seat: u8 },
    Notice(String), // from whoever runs the server, for the player to read
    /// That seat's connection dropped (`away`), or it came back. The match waits for it.
    Away { seat: u8, away: bool },
}

/// What came off the wire.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Decoded<T> {
    Msg(T),
    /// A message number this side doesn't know: from something newer. Ignore it.
    Unknown(u64),
}

/// The bytes are damaged, or break a limit.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Damaged;

type Read<T> = Result<T, Damaged>;

/// Written only when set, so a game or server without tokens sends what it always did.
fn token(w: &mut Writer, field: u32, t: &Token) {
    if *t != Token::default() {
        w.bytes(field, t);
    }
}

fn read_token(v: Value) -> Read<Token> {
    need(v.bytes())?.try_into().map_err(|_| Damaged)
}

fn need<T>(v: Option<T>) -> Read<T> {
    v.ok_or(Damaged)
}

/// Calls `f` for each field, stopping at damage.
fn fields<'a>(b: &'a [u8], mut f: impl FnMut(u32, Value<'a>) -> Read<()>) -> Read<()> {
    let mut r = Reader::new(b);
    while let Some((field, v)) = r.next().map_err(|_| Damaged)? {
        f(field, v)?;
    }
    Ok(())
}

fn text<const N: usize>(v: Value) -> Read<Text<N>> {
    let s = need(v.text())?;
    if s.len() > N {
        return Err(Damaged);
    }
    Ok(Text::new(s))
}

fn long_text(v: Value) -> Read<String> {
    let s = need(v.text())?;
    if s.len() > MAX_TEXT {
        return Err(Damaged);
    }
    Ok(s.to_owned())
}

fn small(v: Value, max: u64) -> Read<u64> {
    let n = need(v.uint())?;
    if n > max {
        return Err(Damaged);
    }
    Ok(n)
}

// --- input -------------------------------------------------------------------------------

/// Ticks go as differences from the one before (the first from the frontier), which keeps
/// each to a byte or two.
fn deltas(start: i64, values: impl Iterator<Item = i64> + Clone) -> impl Iterator<Item = u64> + Clone {
    values.scan(start, |prev, v| {
        let d = v.wrapping_sub(*prev);
        *prev = v;
        Some(zigzag(d))
    })
}

fn write_input(w: &mut Writer, m: &InputMsg) {
    w.uint(1, m.seat as u64);
    w.sint(2, m.frontier);
    w.sint(3, m.ack.wrapping_sub(m.frontier));
    w.sint(4, m.tick.wrapping_sub(m.frontier));
    w.sint(5, m.advantage);
    w.packed(6, deltas(m.frontier, m.changes.iter().map(|c| c.0)));
    w.packed(7, m.changes.iter().map(|c| c.1 as u32 as u64));
    w.packed(8, deltas(m.frontier, m.checks.iter().map(|c| c.0)));
    w.packed_fixed64(9, m.checks.iter().map(|c| c.1));
}

fn read_ticks<const N: usize>(b: &[u8], out: &mut List<i64, N>) -> Read<()> {
    out.clear();
    let mut prev = 0i64; // made relative to the frontier once it's known
    for v in Packed::new(b) {
        prev = prev.wrapping_add(unzigzag(need(v)?));
        if !out.push(prev) {
            return Err(Damaged);
        }
    }
    Ok(())
}

fn read_input(b: &[u8]) -> Read<InputMsg> {
    let mut m = InputMsg::default();
    let mut ticks: List<i64, MAX_CHANGES> = List::default();
    let mut masks: List<i32, MAX_CHANGES> = List::default();
    let mut check_ticks: List<i64, MAX_CHECKS> = List::default();
    let mut hashes: List<i64, MAX_CHECKS> = List::default();
    fields(b, |field, v| {
        match field {
            1 => m.seat = small(v, MAX_SEATS as u64 - 1)? as u8,
            2 => m.frontier = need(v.sint())?,
            3 => m.ack = need(v.sint())?,
            4 => m.tick = need(v.sint())?,
            5 => m.advantage = need(v.sint())?,
            6 => read_ticks(need(v.bytes())?, &mut ticks)?,
            7 => {
                masks.clear();
                for x in Packed::new(need(v.bytes())?) {
                    let x = u32::try_from(need(x)?).map_err(|_| Damaged)?;
                    if !masks.push(x as i32) {
                        return Err(Damaged);
                    }
                }
            }
            8 => read_ticks(need(v.bytes())?, &mut check_ticks)?,
            9 => {
                let b = need(v.bytes())?;
                if b.len() % 8 != 0 || b.len() / 8 > MAX_CHECKS {
                    return Err(Damaged);
                }
                hashes.clear();
                for c in b.chunks_exact(8) {
                    hashes.push(i64::from_le_bytes(c.try_into().unwrap()));
                }
            }
            _ => {}
        }
        Ok(())
    })?;
    if ticks.len() != masks.len() || check_ticks.len() != hashes.len() {
        return Err(Damaged);
    }
    // Fields can come in any order, so the frontier is added to everything relative at the end.
    let f = m.frontier;
    m.ack = m.ack.wrapping_add(f);
    m.tick = m.tick.wrapping_add(f);
    for k in 0..ticks.len() {
        m.changes.push((ticks[k].wrapping_add(f), masks[k]));
    }
    for k in 0..check_ticks.len() {
        m.checks.push((check_ticks[k].wrapping_add(f), hashes[k]));
    }
    Ok(m)
}

// --- game to server ----------------------------------------------------------------------

fn platform_ok(s: &str) -> bool {
    s.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'.' || c == b'_')
}

impl ClientMsg {
    /// Writes the frame onto `out`, after whatever is there.
    pub fn encode_into(&self, out: &mut Vec<u8>) {
        let mut w = Writer { out };
        match self {
            ClientMsg::Hello { protocol, engine, tick_hz, name, platform, features, resume } => {
                w.raw_varint(HELLO);
                w.uint(1, *protocol as u64);
                w.uint(2, *engine as u64);
                w.uint(3, *tick_hz as u64);
                w.bytes(4, name.as_bytes());
                w.bytes(5, platform.as_bytes());
                w.uint(6, *features);
                token(&mut w, 7, resume);
            }
            ClientMsg::Queue { mode } => {
                w.raw_varint(QUEUE);
                w.uint(1, *mode as u64);
            }
            ClientMsg::Room { code, rules } => {
                w.raw_varint(ROOM);
                w.bytes(1, code.as_bytes());
                w.bytes(2, rules);
            }
            ClientMsg::Input(m) => {
                w.raw_varint(INPUT);
                write_input(&mut w, m);
            }
            ClientMsg::Rematch => w.raw_varint(REMATCH),
            ClientMsg::Ping(t) => {
                w.raw_varint(PING);
                w.uint(1, *t);
            }
        }
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        self.encode_into(&mut out);
        out
    }

    /// The message, if it's whole and one this side knows.
    pub fn read(bytes: &[u8]) -> Option<ClientMsg> {
        match ClientMsg::decode(bytes) {
            Ok(Decoded::Msg(m)) => Some(m),
            _ => None,
        }
    }

    pub fn decode(bytes: &[u8]) -> Read<Decoded<ClientMsg>> {
        let mut r = Reader::new(bytes);
        let kind = need(r.raw_varint())?;
        let b = r.b;
        let msg = match kind {
            HELLO => {
                let (mut protocol, mut engine, mut tick_hz, mut features) = (0, 0, 0, 0);
                let (mut name, mut platform) = (Text::default(), Text::default());
                let mut resume = Token::default();
                fields(b, |field, v| {
                    match field {
                        1 => protocol = small(v, u32::MAX as u64)? as u32,
                        2 => engine = small(v, u32::MAX as u64)? as u32,
                        3 => tick_hz = small(v, u32::MAX as u64)? as u32,
                        4 => name = text(v)?,
                        5 => platform = text(v)?,
                        6 => features = need(v.uint())?,
                        7 => resume = read_token(v)?,
                        _ => {}
                    }
                    Ok(())
                })?;
                if !platform_ok(&platform) {
                    return Err(Damaged);
                }
                ClientMsg::Hello { protocol, engine, tick_hz, name, platform, features, resume }
            }
            QUEUE => {
                let mut mode = 0;
                fields(b, |field, v| {
                    if field == 1 {
                        mode = small(v, u32::MAX as u64)? as u32;
                    }
                    Ok(())
                })?;
                ClientMsg::Queue { mode }
            }
            ROOM => {
                let mut code: Text<MAX_ROOM> = Text::default();
                let mut rules = Vec::new();
                fields(b, |field, v| {
                    match field {
                        1 => code = text(v)?,
                        2 => {
                            let r = need(v.bytes())?;
                            if r.len() > MAX_RULES {
                                return Err(Damaged);
                            }
                            rules = r.to_vec();
                        }
                        _ => {}
                    }
                    Ok(())
                })?;
                if code.is_empty() || !code.bytes().all(|c| c.is_ascii_alphanumeric()) {
                    return Err(Damaged);
                }
                ClientMsg::Room { code: Text::new(&code.to_ascii_uppercase()), rules }
            }
            INPUT => ClientMsg::Input(read_input(b)?),
            REMATCH => ClientMsg::Rematch,
            PING => {
                let mut t = 0;
                fields(b, |field, v| {
                    if field == 1 {
                        t = need(v.uint())?;
                    }
                    Ok(())
                })?;
                ClientMsg::Ping(t)
            }
            other => {
                // Still has to be well formed.
                fields(b, |_, _| Ok(()))?;
                return Ok(Decoded::Unknown(other));
            }
        };
        Ok(Decoded::Msg(msg))
    }
}

// --- server to game ----------------------------------------------------------------------

fn seat_size(s: &SeatInfo) -> usize {
    bytes_size(1, s.name.len()) + uint_size(2, s.team as u64) + bytes_size(3, s.platform.len())
}

impl ServerMsg {
    pub fn encode_into(&self, out: &mut Vec<u8>) {
        let mut w = Writer { out };
        match self {
            ServerMsg::Welcome { features, resumed } => {
                w.raw_varint(WELCOME);
                w.uint(1, *features);
                w.uint(2, *resumed);
            }
            ServerMsg::Refused { code, text } => {
                w.raw_varint(REFUSED);
                w.uint(1, *code as u64);
                w.bytes(2, Text::<MAX_TEXT>::new(text).as_bytes());
            }
            ServerMsg::Waiting { room } => {
                w.raw_varint(WAITING);
                w.bytes(1, room.as_bytes());
            }
            ServerMsg::Start { match_id, seed, seat, rules, seats, resume } => {
                w.raw_varint(START);
                w.uint(1, *match_id);
                w.fixed64(2, *seed);
                w.uint(3, *seat as u64);
                w.bytes(4, rules);
                for s in seats.iter() {
                    w.message(5, seat_size(s), |w| {
                        w.bytes(1, s.name.as_bytes());
                        w.uint(2, s.team as u64);
                        w.bytes(3, s.platform.as_bytes());
                    });
                }
                token(&mut w, 6, resume);
            }
            ServerMsg::Input(m) => {
                w.raw_varint(RELAY);
                write_input(&mut w, m);
            }
            ServerMsg::Result { winner, draw, reason, tick } => {
                w.raw_varint(RESULT);
                w.uint(1, *winner as u64);
                w.uint(2, *reason as u64);
                w.sint(3, *tick);
                w.bool(4, *draw);
            }
            ServerMsg::Pong(t) => {
                w.raw_varint(PONG);
                w.uint(1, *t);
            }
            ServerMsg::Left { seat } => {
                w.raw_varint(LEFT);
                w.uint(1, *seat as u64);
            }
            ServerMsg::Notice(text) => {
                w.raw_varint(NOTICE);
                w.bytes(1, Text::<MAX_TEXT>::new(text).as_bytes());
            }
            ServerMsg::Away { seat, away } => {
                w.raw_varint(AWAY);
                w.uint(1, *seat as u64);
                w.bool(2, *away);
            }
        }
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        self.encode_into(&mut out);
        out
    }

    /// The message, if it's whole and one this side knows.
    pub fn read(bytes: &[u8]) -> Option<ServerMsg> {
        match ServerMsg::decode(bytes) {
            Ok(Decoded::Msg(m)) => Some(m),
            _ => None,
        }
    }

    pub fn decode(bytes: &[u8]) -> Read<Decoded<ServerMsg>> {
        let mut r = Reader::new(bytes);
        let kind = need(r.raw_varint())?;
        let b = r.b;
        let one_uint = |b| -> Read<u64> {
            let mut x = 0;
            fields(b, |field, v| {
                if field == 1 {
                    x = need(v.uint())?;
                }
                Ok(())
            })?;
            Ok(x)
        };
        let one_text = |b| -> Read<String> {
            let mut x = String::new();
            fields(b, |field, v| {
                if field == 1 {
                    x = long_text(v)?;
                }
                Ok(())
            })?;
            Ok(x)
        };
        let msg = match kind {
            WELCOME => {
                let (mut features, mut resumed) = (0, 0);
                fields(b, |field, v| {
                    match field {
                        1 => features = need(v.uint())?,
                        2 => resumed = need(v.uint())?,
                        _ => {}
                    }
                    Ok(())
                })?;
                ServerMsg::Welcome { features, resumed }
            }
            REFUSED => {
                let (mut code, mut text) = (Refusal::Other, String::new());
                fields(b, |field, v| {
                    match field {
                        1 => code = Refusal::from(need(v.uint())?),
                        2 => text = long_text(v)?,
                        _ => {}
                    }
                    Ok(())
                })?;
                ServerMsg::Refused { code, text }
            }
            WAITING => {
                let mut room = Text::default();
                fields(b, |field, v| {
                    if field == 1 {
                        room = text(v)?;
                    }
                    Ok(())
                })?;
                ServerMsg::Waiting { room }
            }
            START => {
                let (mut match_id, mut seed, mut seat) = (0, 0, 0);
                let mut rules = Vec::new();
                let mut seats = List::default();
                let mut resume = Token::default();
                fields(b, |field, v| {
                    match field {
                        1 => match_id = need(v.uint())?,
                        2 => seed = need(v.fixed64())?,
                        3 => seat = small(v, MAX_SEATS as u64 - 1)? as u8,
                        4 => {
                            let r = need(v.bytes())?;
                            if r.len() > MAX_RULES {
                                return Err(Damaged);
                            }
                            rules = r.to_vec();
                        }
                        5 => {
                            let mut s = SeatInfo::default();
                            fields(need(v.bytes())?, |f, v| {
                                match f {
                                    1 => s.name = text(v)?,
                                    2 => s.team = small(v, 255)? as u8,
                                    3 => s.platform = text(v)?,
                                    _ => {}
                                }
                                Ok(())
                            })?;
                            if !seats.push(s) {
                                return Err(Damaged);
                            }
                        }
                        6 => resume = read_token(v)?,
                        _ => {}
                    }
                    Ok(())
                })?;
                ServerMsg::Start { match_id, seed, seat, rules, seats, resume }
            }
            RELAY => ServerMsg::Input(read_input(b)?),
            RESULT => {
                let (mut winner, mut draw, mut reason, mut tick) = (0, false, None, 0);
                fields(b, |field, v| {
                    match field {
                        1 => winner = small(v, MAX_SEATS as u64 - 1)? as u8,
                        2 => reason = Some(need(EndReason::from(need(v.uint())?))?),
                        3 => tick = need(v.sint())?,
                        4 => draw = small(v, 1)? == 1,
                        _ => {}
                    }
                    Ok(())
                })?;
                ServerMsg::Result { winner, draw, reason: reason.unwrap_or(EndReason::Played), tick }
            }
            PONG => ServerMsg::Pong(one_uint(b)?),
            LEFT => ServerMsg::Left { seat: u8::try_from(one_uint(b)?).map_err(|_| Damaged)? },
            NOTICE => ServerMsg::Notice(one_text(b)?),
            AWAY => {
                let (mut seat, mut away) = (0, false);
                fields(b, |field, v| {
                    match field {
                        1 => seat = small(v, MAX_SEATS as u64 - 1)? as u8,
                        2 => away = small(v, 1)? == 1,
                        _ => {}
                    }
                    Ok(())
                })?;
                ServerMsg::Away { seat, away }
            }
            other => {
                fields(b, |_, _| Ok(()))?;
                return Ok(Decoded::Unknown(other));
            }
        };
        Ok(Decoded::Msg(msg))
    }
}
