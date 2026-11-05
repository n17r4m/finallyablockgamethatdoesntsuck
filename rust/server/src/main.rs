//! fbg-server [--listen ADDRESS:PORT] [--replays DIR] [--max-connections N]
//! Listens on localhost unless told otherwise. Web games on https need wss://, so put it
//! behind a reverse proxy that handles TLS.

use fbg_server::{serve, Config};
use std::process::ExitCode;

#[tokio::main]
async fn main() -> ExitCode {
    let mut listen = String::from("127.0.0.1:47110");
    let mut config = Config::default();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let value = args.next();
        match (arg.as_str(), value) {
            ("--listen", Some(v)) => listen = v,
            ("--replays", Some(v)) => {
                if let Err(e) = std::fs::create_dir_all(&v) {
                    eprintln!("can't create {v}: {e}");
                    return ExitCode::FAILURE;
                }
                config.replay_dir = Some(v.into());
            }
            ("--max-connections", Some(v)) => match v.parse() {
                Ok(n) => config.max_connections = n,
                Err(_) => {
                    eprintln!("--max-connections needs a number");
                    return ExitCode::FAILURE;
                }
            },
            _ => {
                eprintln!("usage: fbg-server [--listen ADDRESS:PORT] [--replays DIR] [--max-connections N]");
                return ExitCode::FAILURE;
            }
        }
    }
    let listener = match tokio::net::TcpListener::bind(&listen).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!("can't listen on {listen}: {e}");
            return ExitCode::FAILURE;
        }
    };
    println!("listening on {listen}");
    serve(listener, config).await;
    ExitCode::SUCCESS
}
