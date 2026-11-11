//! The match server. `docs/server-protocol.md` says what it does and why.
#![forbid(unsafe_code)]

pub mod admin;
pub mod hub;
pub mod protocol;
pub mod referee;
pub mod store;

pub use hub::{run, serve, Config, Extras};
