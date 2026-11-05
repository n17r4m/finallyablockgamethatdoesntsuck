//! The bridge between Godot and fbg-sim. No rules live here: every method passes straight
//! through, so what the replays prove about fbg-sim stays true on the far side of it.
//!
//! GDScript reaches this through ClassDB, not by name, because a build may not have it.

use fbg_sim::{Replay, State};
use godot::prelude::*;

struct FbgExtension;

#[gdextension]
unsafe impl ExtensionLibrary for FbgExtension {}

#[derive(GodotClass)]
#[class(base=RefCounted)]
pub struct RustSim {
    state: State,
}

#[godot_api]
impl IRefCounted for RustSim {
    fn init(_base: Base<RefCounted>) -> Self {
        RustSim { state: State::new(0, false) }
    }
}

#[godot_api]
impl RustSim {
    #[func]
    fn reset(&mut self, game_seed: i64, solo: bool) {
        self.state = State::new(game_seed, solo);
    }

    #[func]
    fn step(&mut self, input0: i64, input1: i64) {
        self.state.step(input0 as u32, input1 as u32);
    }

    /// Steps once per pair of inputs, so a long run costs one call across the bridge.
    #[func]
    fn step_many(&mut self, inputs: PackedInt32Array) {
        for pair in inputs.as_slice().chunks_exact(2) {
            self.state.step(pair[0] as u32, pair[1] as u32);
        }
    }

    #[func]
    fn copy(&self) -> Gd<RustSim> {
        Gd::from_object(RustSim { state: self.state.clone() })
    }

    #[func]
    fn tick(&self) -> i64 {
        self.state.tick
    }

    #[func]
    fn winner(&self) -> i64 {
        self.state.winner
    }

    #[func]
    fn checksum(&self) -> i64 {
        self.state.checksum()
    }

    #[func]
    fn canonical_bytes(&self) -> PackedByteArray {
        PackedByteArray::from(self.state.canonical_bytes().as_slice())
    }

    /// Empty if the replay is genuine, otherwise why it isn't.
    #[func]
    fn verify_replay(bytes: PackedByteArray) -> GString {
        let result = Replay::decode(bytes.as_slice()).and_then(|r| r.verify().map(|_| ()));
        match result {
            Ok(()) => GString::new(),
            Err(why) => GString::from(why.as_str()),
        }
    }

    #[func]
    fn rules_version() -> i64 {
        i64::from(fbg_sim::consts::RULES_VERSION)
    }
}
