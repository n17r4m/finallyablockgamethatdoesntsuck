//! Protocol 3 is `fbg-proto`, shared with the game through the Godot extension. This adds what
//! only the server needs.

pub use fbg_proto::*;

/// A name as the server keeps it: no control characters, no padding, never empty.
pub fn clean_name(name: &str) -> String {
    let kept: String = name.chars().filter(|c| !c.is_control()).collect();
    let kept = kept.trim();
    if kept.is_empty() { "Player".into() } else { kept.into() }
}
