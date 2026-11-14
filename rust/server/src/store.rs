//! What outlives a restart: matches and their results, how busy the server was, bans, and
//! what the admin did. SQLite, written by one thread of its own so the hub never waits on a
//! disk. Readers (the admin console) open their own connections, which WAL mode allows
//! alongside the writer.

use rusqlite::{params, Connection, OpenFlags};
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{SystemTime, UNIX_EPOCH};

const SCHEMA: &str = "
PRAGMA journal_mode = WAL;
CREATE TABLE IF NOT EXISTS matches (
    id INTEGER PRIMARY KEY,
    started INTEGER NOT NULL,
    ended INTEGER,
    seed INTEGER NOT NULL,
    name0 TEXT, name1 TEXT,
    addr0 TEXT, addr1 TEXT,
    platform0 TEXT, platform1 TEXT,
    winner INTEGER,
    reason TEXT,
    end_tick INTEGER,
    late0 INTEGER, late1 INTEGER,
    replay TEXT
);
-- Every seat of every match. name0..late1 above are only the first two seats, from before
-- matches had more; this is what's read.
CREATE TABLE IF NOT EXISTS seats (
    match INTEGER NOT NULL,
    seat INTEGER NOT NULL,
    team INTEGER NOT NULL,
    name TEXT, addr TEXT, platform TEXT,
    late INTEGER,
    PRIMARY KEY (match, seat)
);
CREATE INDEX IF NOT EXISTS seats_addr ON seats (addr);
CREATE TABLE IF NOT EXISTS samples (
    at INTEGER PRIMARY KEY,
    online INTEGER NOT NULL,
    playing INTEGER NOT NULL,
    waiting INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS bans (
    addr TEXT PRIMARY KEY,
    at INTEGER NOT NULL,
    note TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS audit (
    at INTEGER NOT NULL,
    what TEXT NOT NULL
);
";

pub fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

/// One player of a match, as recorded.
#[derive(Clone, Debug)]
pub struct Seat {
    pub name: String,
    pub addr: String,
    pub platform: String,
    pub team: u8,
}

pub enum Op {
    Started { id: u64, seed: i64, seats: Vec<Seat> },
    /// `winner`: the team, or the team count for a draw. `late`: per seat.
    Ended { id: u64, winner: u8, reason: &'static str, tick: i64, late: Vec<i64>, replay: Option<String> },
    Sample { online: usize, playing: usize, waiting: usize },
    Ban { addr: String, note: String },
    Unban { addr: String },
    Audit(String),
    /// Answers once everything before it is written.
    Flush(mpsc::Sender<()>),
}

/// The writing end. Cheap to clone; the thread stops once every clone is gone.
#[derive(Clone)]
pub struct Store {
    tx: mpsc::Sender<Op>,
    path: PathBuf,
}

/// What the hub needs back when it starts.
pub struct Loaded {
    pub next_match: u64,
    pub bans: Vec<String>,
}

impl Store {
    pub fn open(path: &Path) -> rusqlite::Result<(Store, Loaded)> {
        let conn = Connection::open(path)?;
        conn.execute_batch(SCHEMA)?;
        // Matches recorded before the seats table: their two seats, from the matches row.
        conn.execute_batch(
            "INSERT OR IGNORE INTO seats (match, seat, team, name, addr, platform, late)
                 SELECT id, 0, 0, name0, addr0, platform0, late0 FROM matches WHERE id NOT IN (SELECT match FROM seats);
             INSERT OR IGNORE INTO seats (match, seat, team, name, addr, platform, late)
                 SELECT id, 1, 1, name1, addr1, platform1, late1 FROM matches WHERE id NOT IN (SELECT match FROM seats WHERE seat = 1);",
        )?;
        // Matches that were running when the server last stopped never got a result.
        conn.execute("UPDATE matches SET reason = 'server_stopped' WHERE reason IS NULL", [])?;
        let last: Option<i64> = conn.query_row("SELECT max(id) FROM matches", [], |r| r.get(0))?;
        let bans = conn.prepare("SELECT addr FROM bans")?.query_map([], |r| r.get(0))?.collect::<Result<_, _>>()?;
        let (tx, rx) = mpsc::channel();
        std::thread::Builder::new()
            .name("store".into())
            .spawn(move || {
                for op in rx {
                    if let Err(e) = apply(&conn, op) {
                        eprintln!("store: {e}");
                    }
                }
            })
            .expect("can't start the store thread");
        Ok((Store { tx, path: path.to_owned() }, Loaded { next_match: last.unwrap_or(0) as u64 + 1, bans }))
    }

    pub fn write(&self, op: Op) {
        let _ = self.tx.send(op);
    }

    /// Waits until everything written so far is on disk.
    pub fn flush(&self) {
        let (tx, rx) = mpsc::channel();
        self.write(Op::Flush(tx));
        let _ = rx.recv_timeout(std::time::Duration::from_secs(5));
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

fn apply(c: &Connection, op: Op) -> rusqlite::Result<()> {
    match op {
        Op::Started { id, seed, seats } => {
            let tx = c.unchecked_transaction()?;
            tx.execute("INSERT OR REPLACE INTO matches (id, started, seed) VALUES (?1, ?2, ?3)", params![id as i64, now(), seed])?;
            tx.execute("DELETE FROM seats WHERE match = ?1", [id as i64])?;
            for (k, s) in seats.iter().enumerate() {
                tx.execute(
                    "INSERT INTO seats (match, seat, team, name, addr, platform) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                    params![id as i64, k as i64, s.team, s.name, s.addr, s.platform],
                )?;
            }
            tx.commit()?;
        }
        Op::Ended { id, winner, reason, tick, late, replay } => {
            let tx = c.unchecked_transaction()?;
            tx.execute(
                "UPDATE matches SET ended = ?2, winner = ?3, reason = ?4, end_tick = ?5, replay = ?6 WHERE id = ?1",
                params![id as i64, now(), winner, reason, tick, replay],
            )?;
            for (k, l) in late.iter().enumerate() {
                tx.execute("UPDATE seats SET late = ?3 WHERE match = ?1 AND seat = ?2", params![id as i64, k as i64, l])?;
            }
            tx.commit()?;
        }
        Op::Sample { online, playing, waiting } => {
            c.execute(
                "INSERT OR REPLACE INTO samples (at, online, playing, waiting) VALUES (?1, ?2, ?3, ?4)",
                params![now(), online as i64, playing as i64, waiting as i64],
            )?;
        }
        Op::Ban { addr, note } => {
            c.execute("INSERT OR REPLACE INTO bans (addr, at, note) VALUES (?1, ?2, ?3)", params![addr, now(), note])?;
        }
        Op::Unban { addr } => {
            c.execute("DELETE FROM bans WHERE addr = ?1", params![addr])?;
        }
        Op::Audit(what) => {
            c.execute("INSERT INTO audit (at, what) VALUES (?1, ?2)", params![now(), what])?;
        }
        Op::Flush(done) => {
            let _ = done.send(());
        }
    }
    Ok(())
}

// Reading, for the admin console. Each call opens its own read-only connection.

fn reader(path: &Path) -> rusqlite::Result<Connection> {
    Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)
}

#[derive(Serialize)]
pub struct MatchRow {
    pub id: i64,
    pub started: i64,
    pub ended: Option<i64>,
    pub seed: i64,
    /// Per seat, in seat order.
    pub names: Vec<Option<String>>,
    pub addrs: Vec<Option<String>>,
    pub platforms: Vec<Option<String>>,
    pub teams: Vec<i64>,
    /// The winning team, or the team count for a draw.
    pub winner: Option<i64>,
    pub reason: Option<String>,
    pub end_tick: Option<i64>,
    pub late: Vec<Option<i64>>,
    pub replay: Option<String>,
}

pub fn history(path: &Path, limit: u32) -> rusqlite::Result<Vec<MatchRow>> {
    let c = reader(path)?;
    let mut q = c.prepare("SELECT id, started, ended, seed, winner, reason, end_tick, replay FROM matches ORDER BY id DESC LIMIT ?1")?;
    let mut rows: Vec<MatchRow> = q
        .query_map([limit], |r| {
            Ok(MatchRow {
                id: r.get(0)?,
                started: r.get(1)?,
                ended: r.get(2)?,
                seed: r.get(3)?,
                names: Vec::new(),
                addrs: Vec::new(),
                platforms: Vec::new(),
                teams: Vec::new(),
                winner: r.get(4)?,
                reason: r.get(5)?,
                end_tick: r.get(6)?,
                late: Vec::new(),
                replay: r.get(7)?,
            })
        })?
        .collect::<Result<_, _>>()?;
    let mut seats = c.prepare("SELECT team, name, addr, platform, late FROM seats WHERE match = ?1 ORDER BY seat")?;
    for row in &mut rows {
        let mut it = seats.query([row.id])?;
        while let Some(s) = it.next()? {
            row.teams.push(s.get(0)?);
            row.names.push(s.get(1)?);
            row.addrs.push(s.get(2)?);
            row.platforms.push(s.get(3)?);
            row.late.push(s.get(4)?);
        }
    }
    Ok(rows)
}

pub fn replay_of(path: &Path, id: i64) -> rusqlite::Result<Option<String>> {
    reader(path)?.query_row("SELECT replay FROM matches WHERE id = ?1", [id], |r| r.get(0)).or_else(|e| match e {
        rusqlite::Error::QueryReturnedNoRows => Ok(None),
        e => Err(e),
    })
}

#[derive(Serialize)]
pub struct Stats {
    /// (unix seconds, online, playing, waiting) once a minute, oldest first.
    pub samples: Vec<(i64, i64, i64, i64)>,
    /// How matches ended, most common first.
    pub reasons: Vec<(String, i64)>,
    pub matches: i64,
    pub players: i64, // distinct addresses
    /// Worst input lateness per player-match, in ticks, for the histogram.
    pub late: Vec<i64>,
}

pub fn stats(path: &Path, since: i64) -> rusqlite::Result<Stats> {
    let c = reader(path)?;
    let samples = c
        .prepare("SELECT at, online, playing, waiting FROM samples WHERE at >= ?1 ORDER BY at")?
        .query_map([since], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
        .collect::<Result<_, _>>()?;
    let reasons = c
        .prepare("SELECT coalesce(reason, 'playing'), count(*) FROM matches WHERE started >= ?1 GROUP BY 1 ORDER BY 2 DESC")?
        .query_map([since], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<Result<_, _>>()?;
    let matches = c.query_row("SELECT count(*) FROM matches WHERE started >= ?1", [since], |r| r.get(0))?;
    let players = c.query_row(
        "SELECT count(DISTINCT s.addr) FROM seats s JOIN matches m ON m.id = s.match WHERE m.started >= ?1",
        [since],
        |r| r.get(0),
    )?;
    let late = c
        .prepare("SELECT s.late FROM seats s JOIN matches m ON m.id = s.match WHERE m.started >= ?1 AND s.late IS NOT NULL")?
        .query_map([since], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    Ok(Stats { samples, reasons, matches, players, late })
}

#[derive(Serialize)]
pub struct Ban {
    pub addr: String,
    pub at: i64,
    pub note: String,
}

pub fn bans(path: &Path) -> rusqlite::Result<Vec<Ban>> {
    let c = reader(path)?;
    let mut q = c.prepare("SELECT addr, at, note FROM bans ORDER BY at DESC")?;
    let rows = q.query_map([], |r| Ok(Ban { addr: r.get(0)?, at: r.get(1)?, note: r.get(2)? }))?;
    rows.collect()
}

#[derive(Serialize)]
pub struct AuditRow {
    pub at: i64,
    pub what: String,
}

pub fn audit(path: &Path, limit: u32) -> rusqlite::Result<Vec<AuditRow>> {
    let c = reader(path)?;
    let mut q = c.prepare("SELECT at, what FROM audit ORDER BY rowid DESC LIMIT ?1")?;
    let rows = q.query_map([limit], |r| Ok(AuditRow { at: r.get(0)?, what: r.get(1)? }))?;
    rows.collect()
}
