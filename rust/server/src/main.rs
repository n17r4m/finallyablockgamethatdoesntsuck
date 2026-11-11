//! fbg-server [--listen ADDRESS:PORT] [--replays DIR] [--db FILE] [--max-connections N]
//!            [--admin ADDRESS:PORT | --admin off] [--admin-password-file FILE] [--trust-proxy]
//!
//! Listens on localhost unless told otherwise. Web games on https need wss://, so put it
//! behind a reverse proxy that handles TLS, and pass --trust-proxy so the proxy's X-Real-IP
//! counts as the player's address. The admin console listens on 127.0.0.1:47111 by default.
//! See docs/server-admin.md.

use fbg_server::admin::{serve_admin, AdminConfig};
use fbg_server::store::Store;
use fbg_server::{run, Config, Extras};
use std::path::PathBuf;
use std::process::ExitCode;

const USAGE: &str = "usage: fbg-server [--listen ADDRESS:PORT] [--replays DIR] [--db FILE] [--max-connections N]
                  [--admin ADDRESS:PORT | --admin off] [--admin-password-file FILE] [--trust-proxy]";

fn fail(why: impl std::fmt::Display) -> ExitCode {
    eprintln!("{why}");
    ExitCode::FAILURE
}

#[tokio::main]
async fn main() -> ExitCode {
    let mut listen = String::from("127.0.0.1:47110");
    let mut admin = Some(String::from("127.0.0.1:47111"));
    let mut password = None;
    let mut db: Option<PathBuf> = None;
    let mut config = Config::default();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        if arg == "--trust-proxy" {
            config.trust_proxy = true;
            continue;
        }
        let Some(v) = args.next() else { return fail(USAGE) };
        match arg.as_str() {
            "--listen" => listen = v,
            "--replays" => {
                if let Err(e) = std::fs::create_dir_all(&v) {
                    return fail(format!("can't create {v}: {e}"));
                }
                config.replay_dir = Some(v.into());
            }
            "--db" => db = Some(v.into()),
            "--max-connections" => match v.parse() {
                Ok(n) => config.max_connections = n,
                Err(_) => return fail("--max-connections needs a number"),
            },
            "--admin" => admin = (v != "off").then_some(v),
            "--admin-password-file" => match std::fs::read_to_string(&v) {
                Ok(text) if !text.trim().is_empty() => password = Some(text.trim().to_owned()),
                Ok(_) => return fail(format!("{v} is empty")),
                Err(e) => return fail(format!("can't read {v}: {e}")),
            },
            _ => return fail(USAGE),
        }
    }

    let mut extras = Extras::default();
    if let Some(path) = &db {
        match Store::open(path) {
            Ok(opened) => extras.store = Some(opened),
            Err(e) => return fail(format!("can't open {}: {e}", path.display())),
        }
    }
    let listener = match tokio::net::TcpListener::bind(&listen).await {
        Ok(l) => l,
        Err(e) => return fail(format!("can't listen on {listen}: {e}")),
    };
    println!("listening on {listen}");
    if let Some(addr) = admin {
        let admin_listener = match tokio::net::TcpListener::bind(&addr).await {
            Ok(l) => l,
            Err(e) => return fail(format!("can't listen on {addr} for the admin console: {e}")),
        };
        let (tx, rx) = tokio::sync::mpsc::channel(64);
        extras.admin = Some(rx);
        let config = AdminConfig { password, db: db.clone(), replay_dir: config.replay_dir.clone() };
        tokio::spawn(serve_admin(admin_listener, tx, config));
        println!("admin console on http://{addr}/");
    }

    let mut term = match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
        Ok(s) => s,
        Err(e) => return fail(format!("can't watch for SIGTERM: {e}")),
    };
    tokio::select! {
        _ = run(listener, config, extras) => {}
        _ = tokio::signal::ctrl_c() => println!("interrupted: stopping"),
        _ = term.recv() => println!("terminated: stopping"),
    }
    ExitCode::SUCCESS
}
