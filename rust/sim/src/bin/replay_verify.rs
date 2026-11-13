//! Re-simulates replay files and reports whether each one is genuine.
//!   cargo run --release --bin replay_verify -- FILE_OR_DIR...

use fbg_sim::consts::TICK_HZ;
use fbg_sim::Replay;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

fn check(path: &Path) -> Result<String, String> {
    let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
    let r = Replay::decode(&bytes)?;
    let end = r.verify()?;
    let winner = match end.winner {
        -1 => "unfinished".to_string(),
        w if w == end.team_count as i64 => "draw".to_string(),
        w => format!("team {} won", w + 1),
    };
    let inputs: Vec<String> = r.inputs.iter().map(|i| i.len().to_string()).collect();
    Ok(format!(
        "{:.1} s, teams {:?}, {winner}, inputs {}",
        r.end_tick as f64 / TICK_HZ as f64,
        r.teams,
        inputs.join("/")
    ))
}

fn main() -> ExitCode {
    let mut files: Vec<PathBuf> = Vec::new();
    for arg in std::env::args().skip(1) {
        let path = PathBuf::from(arg);
        match std::fs::read_dir(&path) {
            Ok(dir) => {
                let mut found: Vec<PathBuf> = dir
                    .flatten()
                    .map(|e| e.path())
                    .filter(|p| p.extension().is_some_and(|x| x == "fbgr"))
                    .collect();
                found.sort();
                files.append(&mut found);
            }
            Err(_) => files.push(path),
        }
    }
    let mut failed = 0;
    for f in &files {
        match check(f) {
            Ok(summary) => println!("ok   {}: {summary}", f.display()),
            Err(e) => {
                failed += 1;
                println!("FAIL {}: {e}", f.display());
            }
        }
    }
    println!("{} replays, {failed} failed", files.len());
    if failed == 0 && !files.is_empty() {
        println!("PASS");
        ExitCode::SUCCESS
    } else {
        println!("FAIL");
        ExitCode::FAILURE
    }
}
