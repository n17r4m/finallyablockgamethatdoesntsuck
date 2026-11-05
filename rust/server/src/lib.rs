//! The match server. `docs/server-protocol.md` says what it does and why.
#![forbid(unsafe_code)]

pub mod hub;
pub mod protocol;
pub mod referee;

pub use hub::{serve, Config};
