//! The messages between the game and the match server: types, and a codec of our own on
//! protobuf's wire encoding. The server uses it over WebSocket; the game uses it through the
//! Godot extension, so both ends run this same code. No sockets or storage here.
#![forbid(unsafe_code)]

pub mod msg;
pub mod wire;

pub use msg::*;
