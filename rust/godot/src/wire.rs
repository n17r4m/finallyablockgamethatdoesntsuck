//! FbgWire: the game's end of the match server's protocol, from fbg-proto, the same code the
//! server runs. GDScript hands it Dictionaries and gets bytes, and the other way round.
//! Input Dictionaries are the ones RollbackSession already speaks:
//! {f, a, s, v, t: PackedInt64Array, m: PackedInt32Array, c: {tick: hash}}.

use fbg_proto::{features, ClientMsg, Decoded, EndReason, InputMsg, List, Refusal, SeatInfo, ServerMsg, Text, MAX_SEATS, PROTOCOL};
use godot::prelude::*;

// The two versions of the bindings in use (see Cargo.toml) spell dictionary access differently.
fn put(d: &mut VarDictionary, k: &str, v: Variant) {
    #[cfg(not(target_family = "wasm"))]
    d.set(GString::from(k), v);
    #[cfg(target_family = "wasm")]
    d.set(&k.to_variant(), &v);
}

fn get(d: &VarDictionary, k: &str) -> Option<Variant> {
    #[cfg(not(target_family = "wasm"))]
    return d.get(GString::from(k));
    #[cfg(target_family = "wasm")]
    return d.get(&k.to_variant());
}

fn int(d: &VarDictionary, k: &str) -> i64 {
    get(d, k).and_then(|v| v.try_to::<i64>().ok()).unwrap_or(0)
}

fn string(d: &VarDictionary, k: &str) -> String {
    get(d, k).and_then(|v| v.try_to::<GString>().ok()).map(|s| s.to_string()).unwrap_or_default()
}

fn bytes(d: &VarDictionary, k: &str) -> Vec<u8> {
    get(d, k).and_then(|v| v.try_to::<PackedByteArray>().ok()).map(|b| b.as_slice().to_vec()).unwrap_or_default()
}

fn pba(b: &[u8]) -> PackedByteArray {
    PackedByteArray::from(b)
}

fn input_from(d: &VarDictionary) -> InputMsg {
    let mut m = InputMsg { seat: int(d, "seat") as u8, frontier: int(d, "f"), ack: int(d, "a"), tick: int(d, "s"), advantage: int(d, "v"), ..Default::default() };
    let t = get(d, "t").and_then(|v| v.try_to::<PackedInt64Array>().ok()).unwrap_or_default();
    let masks = get(d, "m").and_then(|v| v.try_to::<PackedInt32Array>().ok()).unwrap_or_default();
    for (tick, mask) in t.as_slice().iter().zip(masks.as_slice()) {
        m.changes.push((*tick, *mask));
    }
    if let Some(c) = get(d, "c").and_then(|v| v.try_to::<VarDictionary>().ok()) {
        let mut checks: Vec<(i64, i64)> = c.iter_shared().filter_map(|(k, v)| Some((k.try_to::<i64>().ok()?, v.try_to::<i64>().ok()?))).collect();
        checks.sort();
        m.checks = List::of(&checks);
    }
    m
}

fn input_to(m: &InputMsg, d: &mut VarDictionary) {
    put(d, "seat", i64::from(m.seat).to_variant());
    put(d, "f", m.frontier.to_variant());
    put(d, "a", m.ack.to_variant());
    put(d, "s", m.tick.to_variant());
    put(d, "v", m.advantage.to_variant());
    let t: Vec<i64> = m.changes.iter().map(|c| c.0).collect();
    let masks: Vec<i32> = m.changes.iter().map(|c| c.1).collect();
    put(d, "t", PackedInt64Array::from(t.as_slice()).to_variant());
    put(d, "m", PackedInt32Array::from(masks.as_slice()).to_variant());
    let mut c = VarDictionary::new();
    for (k, h) in m.checks.iter() {
        put_int_key(&mut c, *k, *h);
    }
    put(d, "c", c.to_variant());
}

fn put_int_key(d: &mut VarDictionary, k: i64, v: i64) {
    #[cfg(not(target_family = "wasm"))]
    d.set(k, v);
    #[cfg(target_family = "wasm")]
    d.set(&k.to_variant(), &v.to_variant());
}

fn reason_name(r: EndReason) -> i64 {
    r as i64
}

#[derive(GodotClass)]
#[class(base=RefCounted, init)]
pub struct FbgWire {}

#[godot_api]
impl FbgWire {
    #[func]
    fn protocol() -> i64 {
        i64::from(PROTOCOL)
    }

    /// What this game can do beyond the protocol's core.
    #[func]
    fn features() -> i64 {
        features::CUSTOM_RULES as i64
    }

    #[func]
    fn hello(name: GString, platform: GString) -> PackedByteArray {
        let m = ClientMsg::Hello {
            protocol: PROTOCOL,
            engine: u32::from(fbg_sim::consts::RULES_VERSION),
            tick_hz: u32::from(fbg_sim::consts::TICK_HZ),
            name: Text::new(&name.to_string()),
            platform: Text::new(&platform.to_string()),
            features: features::CUSTOM_RULES,
        };
        pba(&m.encode())
    }

    #[func]
    fn queue(mode: i64) -> PackedByteArray {
        pba(&ClientMsg::Queue { mode: mode as u32 }.encode())
    }

    /// rules: SimRules.encode(), or empty for the standard rules.
    #[func]
    fn room(code: GString, rules: PackedByteArray) -> PackedByteArray {
        pba(&ClientMsg::Room { code: Text::new(&code.to_string()), rules: rules.as_slice().to_vec() }.encode())
    }

    #[func]
    fn input(pkt: VarDictionary) -> PackedByteArray {
        pba(&ClientMsg::Input(input_from(&pkt)).encode())
    }

    #[func]
    fn rematch() -> PackedByteArray {
        pba(&ClientMsg::Rematch.encode())
    }

    #[func]
    fn ping(t: i64) -> PackedByteArray {
        pba(&ClientMsg::Ping(t as u64).encode())
    }

    /// A message from the server as a Dictionary with a "type". {"type": "unknown"} for one
    /// from a newer server, which the game should ignore; {} for damaged bytes.
    #[func]
    fn decode(bytes: PackedByteArray) -> VarDictionary {
        let mut d = VarDictionary::new();
        let msg = match ServerMsg::decode(bytes.as_slice()) {
            Ok(Decoded::Msg(m)) => m,
            Ok(Decoded::Unknown(_)) => {
                put(&mut d, "type", "unknown".to_variant());
                return d;
            }
            Err(_) => return d,
        };
        let kind = match msg {
            ServerMsg::Welcome { features } => {
                put(&mut d, "features", (features as i64).to_variant());
                "welcome"
            }
            ServerMsg::Refused { code, text } => {
                put(&mut d, "code", (code as i64).to_variant());
                put(&mut d, "text", text.to_variant());
                "refused"
            }
            ServerMsg::Waiting { room } => {
                put(&mut d, "room", room.to_string().to_variant());
                "waiting"
            }
            ServerMsg::Start { match_id, seed, seat, rules, seats } => {
                put(&mut d, "match_id", (match_id as i64).to_variant());
                put(&mut d, "seed", seed.to_variant());
                put(&mut d, "seat", i64::from(seat).to_variant());
                put(&mut d, "rules", pba(&rules).to_variant());
                let mut list = VarArray::new();
                for s in seats.iter() {
                    let mut sd = VarDictionary::new();
                    put(&mut sd, "name", s.name.to_string().to_variant());
                    put(&mut sd, "team", i64::from(s.team).to_variant());
                    put(&mut sd, "platform", s.platform.to_string().to_variant());
                    list.push(&sd.to_variant());
                }
                put(&mut d, "seats", list.to_variant());
                "start"
            }
            ServerMsg::Input(m) => {
                input_to(&m, &mut d);
                "input"
            }
            ServerMsg::Result { winner, draw, reason, tick } => {
                put(&mut d, "winner", i64::from(winner).to_variant());
                put(&mut d, "draw", draw.to_variant());
                put(&mut d, "reason", reason_name(reason).to_variant());
                put(&mut d, "tick", tick.to_variant());
                "result"
            }
            ServerMsg::Pong(t) => {
                put(&mut d, "t", (t as i64).to_variant());
                "pong"
            }
            ServerMsg::Left { seat } => {
                put(&mut d, "seat", i64::from(seat).to_variant());
                "left"
            }
            ServerMsg::Notice(text) => {
                put(&mut d, "text", text.to_variant());
                "notice"
            }
        };
        put(&mut d, "type", kind.to_variant());
        d
    }

    /// The server's side, for tests that play the server: a Dictionary as `decode` returns
    /// one, back to bytes. Empty for a type it doesn't know.
    #[func]
    fn server_bytes(d: VarDictionary) -> PackedByteArray {
        let msg = match string(&d, "type").as_str() {
            "welcome" => ServerMsg::Welcome { features: int(&d, "features") as u64 },
            "refused" => ServerMsg::Refused { code: refusal(int(&d, "code")), text: string(&d, "text") },
            "waiting" => ServerMsg::Waiting { room: Text::new(&string(&d, "room")) },
            "start" => {
                let mut seats: List<SeatInfo, MAX_SEATS> = List::default();
                if let Some(list) = get(&d, "seats").and_then(|v| v.try_to::<VarArray>().ok()) {
                    for v in list.iter_shared() {
                        if let Ok(sd) = v.try_to::<VarDictionary>() {
                            seats.push(SeatInfo { name: Text::new(&string(&sd, "name")), team: int(&sd, "team") as u8, platform: Text::new(&string(&sd, "platform")) });
                        }
                    }
                }
                ServerMsg::Start { match_id: int(&d, "match_id") as u64, seed: int(&d, "seed"), seat: int(&d, "seat") as u8, rules: bytes(&d, "rules"), seats }
            }
            "input" => ServerMsg::Input(input_from(&d)),
            "result" => ServerMsg::Result {
                winner: int(&d, "winner") as u8,
                draw: get(&d, "draw").and_then(|v| v.try_to::<bool>().ok()).unwrap_or(false),
                reason: end_reason(int(&d, "reason")),
                tick: int(&d, "tick"),
            },
            "pong" => ServerMsg::Pong(int(&d, "t") as u64),
            "left" => ServerMsg::Left { seat: int(&d, "seat") as u8 },
            "notice" => ServerMsg::Notice(string(&d, "text")),
            _ => return PackedByteArray::new(),
        };
        pba(&msg.encode())
    }
}

fn refusal(v: i64) -> Refusal {
    match v {
        1 => Refusal::Update,
        2 => Refusal::Draining,
        3 => Refusal::Banned,
        4 => Refusal::Full,
        5 => Refusal::BadRules,
        _ => Refusal::Other,
    }
}

fn end_reason(v: i64) -> EndReason {
    match v {
        1 => EndReason::Left,
        2 => EndReason::Stalled,
        3 => EndReason::WrongState,
        4 => EndReason::BadInput,
        5 => EndReason::TooLong,
        6 => EndReason::Ended,
        _ => EndReason::Played,
    }
}
