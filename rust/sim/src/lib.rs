//! The game's rules in Rust. `docs/engine-contract.md` says what this must match, and
//! the recorded games in `tests/golden/` prove it does, byte for byte, on every checkpoint.
#![forbid(unsafe_code)]

pub mod board;
pub mod consts;
pub mod replay;
pub mod rules;
pub mod state;

pub use board::Board;
pub use replay::Replay;
pub use rules::Rules;
pub use state::State;

use sha2::{Digest, Sha256};

/// First 8 bytes of SHA-256, read little-endian.
pub fn hash64(bytes: &[u8]) -> i64 {
    let digest = Sha256::digest(bytes);
    let mut head = [0u8; 8];
    head.copy_from_slice(&digest[..8]);
    i64::from_le_bytes(head)
}
