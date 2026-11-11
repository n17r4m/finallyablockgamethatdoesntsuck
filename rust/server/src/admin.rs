//! The admin console: one page and a small JSON API, on a listener of its own. It listens on
//! localhost, for an ssh tunnel. With a password it asks for one (HTTP Basic), for when a
//! reverse proxy puts it somewhere else. Everything live comes from the hub over `AdminCmd`.
//! History and stats come straight from the store.

use crate::hub::{Action, AdminCmd};
use crate::store;
use axum::body::Body;
use axum::extract::{Path, Query, Request, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::Engine;
use serde::Deserialize;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio::sync::{mpsc, oneshot};

const PAGE: &str = include_str!("admin.html");

#[derive(Clone)]
pub struct AdminConfig {
    /// None: only answer requests addressed to localhost. Some: ask for this password.
    pub password: Option<String>,
    pub db: Option<PathBuf>,
    pub replay_dir: Option<PathBuf>,
}

struct Ctx {
    hub: mpsc::Sender<AdminCmd>,
    config: AdminConfig,
}

type Shared = Arc<Ctx>;

/// Serves the console until the process ends.
pub async fn serve_admin(listener: TcpListener, hub: mpsc::Sender<AdminCmd>, config: AdminConfig) {
    let ctx = Arc::new(Ctx { hub, config });
    let app = Router::new()
        .route("/", get(|| async { Html(PAGE) }))
        .route("/api/state", get(state))
        .route("/api/watch/{id}", get(watch))
        .route("/api/act", post(act))
        .route("/api/history", get(history))
        .route("/api/stats", get(stats))
        .route("/api/bans", get(bans))
        .route("/api/audit", get(audit))
        .route("/api/replay/{id}", get(replay))
        .layer(middleware::from_fn_with_state(ctx.clone(), guard))
        .with_state(ctx);
    if let Err(e) = axum::serve(listener, app).await {
        eprintln!("admin console stopped: {e}");
    }
}

/// Who may use the console, and how actions are protected from other web pages.
async fn guard(State(ctx): State<Shared>, req: Request, next: Next) -> Response {
    let headers = req.headers();
    match &ctx.config.password {
        Some(password) => {
            if !basic_auth_ok(headers, password) {
                return (StatusCode::UNAUTHORIZED, [(header::WWW_AUTHENTICATE, "Basic realm=\"fbg admin\"")], "password needed").into_response();
            }
        }
        None => {
            // A page on some other site can point a name it controls at 127.0.0.1. Its
            // requests still say that name, so they stop here.
            let host = headers.get(header::HOST).and_then(|h| h.to_str().ok()).unwrap_or("");
            let name = host.rsplit_once(':').map_or(host, |(n, port)| if port.chars().all(|c| c.is_ascii_digit()) { n } else { host });
            if !matches!(name, "localhost" | "127.0.0.1" | "[::1]") {
                return (StatusCode::FORBIDDEN, "the console only answers on localhost").into_response();
            }
        }
    }
    // Another site's form can post here, but it can't add a header without our permission,
    // which nothing here ever gives.
    if req.method() != axum::http::Method::GET && headers.get("x-fbg-admin").is_none() {
        return (StatusCode::FORBIDDEN, "missing x-fbg-admin header").into_response();
    }
    next.run(req).await
}

fn basic_auth_ok(headers: &HeaderMap, password: &str) -> bool {
    let Some(value) = headers.get(header::AUTHORIZATION).and_then(|v| v.to_str().ok()) else { return false };
    let Some(encoded) = value.strip_prefix("Basic ") else { return false };
    let Ok(decoded) = base64::engine::general_purpose::STANDARD.decode(encoded.trim()) else { return false };
    let Ok(text) = String::from_utf8(decoded) else { return false };
    // Any user name; only the password counts. Compared in full so timing says nothing.
    let given = text.split_once(':').map_or("", |(_, p)| p).as_bytes();
    let want = password.as_bytes();
    let mut diff = given.len() ^ want.len();
    for i in 0..given.len().max(want.len()) {
        diff |= usize::from(given.get(i).copied().unwrap_or(0) ^ want.get(i).copied().unwrap_or(0));
    }
    diff == 0
}

fn gone() -> Response {
    (StatusCode::SERVICE_UNAVAILABLE, "the server is stopping").into_response()
}

async fn ask<T>(ctx: &Ctx, make: impl FnOnce(oneshot::Sender<T>) -> AdminCmd) -> Option<T> {
    let (tx, rx) = oneshot::channel();
    ctx.hub.send(make(tx)).await.ok()?;
    rx.await.ok()
}

async fn state(State(ctx): State<Shared>) -> Response {
    match ask(&ctx, AdminCmd::Snapshot).await {
        Some(s) => Json(s).into_response(),
        None => gone(),
    }
}

async fn watch(State(ctx): State<Shared>, Path(id): Path<u64>) -> Response {
    match ask(&ctx, |tx| AdminCmd::Watch(id, tx)).await {
        Some(Some(w)) => Json(w).into_response(),
        Some(None) => (StatusCode::NOT_FOUND, "no such match").into_response(),
        None => gone(),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum ActReq {
    Kick { conn: u64 },
    End { r#match: u64 },
    Notice { text: String },
    Drain { on: bool, exit: bool },
    Ban { addr: String, note: Option<String> },
    Unban { addr: String },
}

async fn act(State(ctx): State<Shared>, Json(req): Json<ActReq>) -> Response {
    let action = match req {
        ActReq::Kick { conn } => Action::Kick(conn),
        ActReq::End { r#match } => Action::End(r#match),
        ActReq::Notice { text } => Action::Notice(text),
        ActReq::Drain { on, exit } => Action::Drain { on, exit },
        ActReq::Ban { addr, note } => Action::Ban { addr, note: note.unwrap_or_default() },
        ActReq::Unban { addr } => Action::Unban(addr),
    };
    match ask(&ctx, |tx| AdminCmd::Act(action, tx)).await {
        Some(Ok(msg)) => (StatusCode::OK, msg).into_response(),
        Some(Err(msg)) => (StatusCode::BAD_REQUEST, msg).into_response(),
        None => gone(),
    }
}

/// Runs a store query off the async threads. 404 when there's no database.
async fn from_db<T: serde::Serialize + Send + 'static>(
    ctx: &Ctx,
    query: impl FnOnce(&std::path::Path) -> rusqlite::Result<T> + Send + 'static,
) -> Response {
    let Some(db) = ctx.config.db.clone() else {
        return (StatusCode::NOT_FOUND, "this server keeps no database (--db)").into_response();
    };
    match tokio::task::spawn_blocking(move || query(&db)).await {
        Ok(Ok(v)) => Json(v).into_response(),
        Ok(Err(e)) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

#[derive(Deserialize)]
struct Limit {
    limit: Option<u32>,
}

#[derive(Deserialize)]
struct Since {
    hours: Option<i64>,
}

async fn history(State(ctx): State<Shared>, Query(q): Query<Limit>) -> Response {
    let limit = q.limit.unwrap_or(100).min(1000);
    from_db(&ctx, move |db| store::history(db, limit)).await
}

async fn stats(State(ctx): State<Shared>, Query(q): Query<Since>) -> Response {
    let since = store::now() - q.hours.unwrap_or(24).clamp(1, 24 * 90) * 3600;
    from_db(&ctx, move |db| store::stats(db, since)).await
}

async fn bans(State(ctx): State<Shared>) -> Response {
    from_db(&ctx, store::bans).await
}

async fn audit(State(ctx): State<Shared>, Query(q): Query<Limit>) -> Response {
    let limit = q.limit.unwrap_or(50).min(1000);
    from_db(&ctx, move |db| store::audit(db, limit)).await
}

async fn replay(State(ctx): State<Shared>, Path(id): Path<i64>) -> Response {
    let (Some(db), Some(dir)) = (ctx.config.db.clone(), ctx.config.replay_dir.clone()) else {
        return (StatusCode::NOT_FOUND, "this server keeps no replays (--db and --replays)").into_response();
    };
    let name = match tokio::task::spawn_blocking(move || store::replay_of(&db, id)).await {
        Ok(Ok(Some(name))) => name,
        Ok(Ok(None)) => return (StatusCode::NOT_FOUND, "no replay for that match").into_response(),
        _ => return (StatusCode::INTERNAL_SERVER_ERROR, "can't read the database").into_response(),
    };
    // The server wrote this name itself, but a database is a file anyone with access can edit.
    if name.contains(['/', '\\']) || name.starts_with('.') {
        return (StatusCode::BAD_REQUEST, "bad replay name").into_response();
    }
    match tokio::fs::read(dir.join(&name)).await {
        Ok(bytes) => (
            [(header::CONTENT_TYPE, "application/octet-stream".to_owned()), (header::CONTENT_DISPOSITION, format!("attachment; filename=\"{name}\""))],
            Body::from(bytes),
        )
            .into_response(),
        Err(_) => (StatusCode::NOT_FOUND, "the replay file is gone").into_response(),
    }
}
