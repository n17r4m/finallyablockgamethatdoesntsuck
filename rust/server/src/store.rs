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

/// One side of a match, as recorded.
#[derive(Clone, Debug)]
pub struct Seat {
    pub name: String,
    pub addr: String,
    pub platform: String,
}

pub enum Op {
    Started { id: u64, seed: i64, seats: [Seat; 2] },
    Ended { id: u64, winner: u8, reason: &'static str, tick: i64, late: [i64; 2], replay: Option<String> },
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
        Op::Started { id, seed, seats: [a, b] } => {
            c.execute(
                "INSERT OR REPLACE INTO matches (id, started, seed, name0, name1, addr0, addr1, platform0, platform1)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![id as i64, now(), seed, a.name, b.name, a.addr, b.addr, a.platform, b.platform],
            )?;
        }
        Op::Ended { id, winner, reason, tick, late, replay } => {
            c.execute(
                "UPDATE matches SET ended = ?2, winner = ?3, reason = ?4, end_tick = ?5, late0 = ?6, late1 = ?7, replay = ?8 WHERE id = ?1",
                params![id as i64, now(), winner, reason, tick, late[0], late[1], replay],
            )?;
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
    pub names: [Option<String>; 2],
    pub addrs: [Option<String>; 2],
    pub platforms: [Option<String>; 2],
    pub winner: Option<i64>,
    pub reason: Option<String>,
    pub end_tick: Option<i64>,
    pub late: [Option<i64>; 2],
    pub replay: Option<String>,
}

pub fn history(path: &Path, limit: u32) -> rusqlite::Result<Vec<MatchRow>> {
    let c = reader(path)?;
    let mut q = c.prepare(
        "SELECT id, started, ended, seed, name0, name1, addr0, addr1, platform0, platform1,
                winner, reason, end_tick, late0, late1, replay
         FROM matches ORDER BY id DESC LIMIT ?1",
    )?;
    let rows = q.query_map([limit], |r| {
        Ok(MatchRow {
            id: r.get(0)?,
            started: r.get(1)?,
            ended: r.get(2)?,
            seed: r.get(3)?,
            names: [r.get(4)?, r.get(5)?],
            addrs: [r.get(6)?, r.get(7)?],
            platforms: [r.get(8)?, r.get(9)?],
            winner: r.get(10)?,
            reason: r.get(11)?,
            end_tick: r.get(12)?,
            late: [r.get(13)?, r.get(14)?],
            replay: r.get(15)?,
        })
    })?;
    rows.collect()
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
        "SELECT count(DISTINCT a) FROM (SELECT addr0 AS a FROM matches WHERE started >= ?1 UNION SELECT addr1 FROM matches WHERE started >= ?1)",
        [since],
        |r| r.get(0),
    )?;
    let late = c
        .prepare("SELECT late0 FROM matches WHERE started >= ?1 AND late0 IS NOT NULL UNION ALL SELECT late1 FROM matches WHERE started >= ?1 AND late1 IS NOT NULL")?
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
