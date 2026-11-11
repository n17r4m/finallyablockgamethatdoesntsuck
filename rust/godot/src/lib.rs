//! The bridge between Godot and fbg-sim. No rules live here: every method passes straight
//! through, so what the replays prove about fbg-sim stays true on the far side of it.
//!
//! GDScript reaches this through ClassDB, not by name, because a build may not have it.

use fbg_sim::{Replay, Rules, State};
use std::sync::Arc;
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

    /// A match on the rules these bytes encode (SimRules.encode()). False, and nothing
    /// changes, if Rust won't play them.
    #[func]
    fn reset_with_rules(&mut self, game_seed: i64, solo: bool, rules: PackedByteArray) -> bool {
        match Rules::decode(rules.as_slice()) {
            Some(r) => {
                self.state = State::with_rules(game_seed, solo, Arc::new(r));
                true
            }
            None => false,
        }
    }

    /// Returns the winner, so GDScript needn't cross the bridge again to learn it.
    #[func]
    fn step(&mut self, input0: i64, input1: i64) -> i64 {
        self.state.step(input0 as u32, input1 as u32);
        self.state.winner
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

    /// Every field of one board, in the order of SimBoard.STATE. It's how the renderers and
    /// CPU players see the game, and RustState proves against the hash that nothing is missed.
    #[func]
    fn board_fields(&self, p: i64) -> Array<Variant> {
        let b = &self.state.boards[p as usize];
        let mut out = Array::new();
        let mut add = |v: Variant| out.push(&v);
        add(PackedByteArray::from(b.color.as_slice()).to_variant());
        add(PackedByteArray::from(b.st.as_slice()).to_variant());
        add(PackedInt32Array::from(b.tm.as_slice()).to_variant());
        add(PackedInt32Array::from(b.aux.as_slice()).to_variant());
        add(PackedByteArray::from(b.chain.as_slice()).to_variant());
        add(PackedInt32Array::from(b.gid.as_slice()).to_variant());
        add(PackedByteArray::from(b.reveal.as_slice()).to_variant());
        add(PackedByteArray::from(b.next_row.as_slice()).to_variant());
        add(b.cursor_x.to_variant());
        add(b.cursor_y.to_variant());
        add(i64::from(b.prev_input).to_variant());
        add(b.hold.to_variant());
        add(b.rise.to_variant());
        add(b.stop_t.to_variant());
        add(b.health.to_variant());
        add(i64::from(b.rng).to_variant());
        add(b.score.to_variant());
        add(b.lost.to_variant());
        add(b.busy.to_variant());
        add(b.need_scan.to_variant());
        add(b.need_support.to_variant());
        add(b.has_matched.to_variant());
        add(b.chain_n.to_variant());
        add(PackedInt32Array::from(b.outbox.as_slice()).to_variant());
        add(PackedInt32Array::from(b.gar_q.as_slice()).to_variant());
        add(b.gar_t.to_variant());
        add(b.gar_side.to_variant());
        add(b.next_gid.to_variant());
        add(b.fx_combo.to_variant());
        add(b.fx_chain.to_variant());
        add(b.fx_t.to_variant());
        add(b.age.to_variant());
        add(b.sent.to_variant());
        add(b.best_chain.to_variant());
        add(b.swaps.to_variant());
        add(b.time_rate.to_variant());
        add(b.world_acc.to_variant());
        add(b.ramp_t.to_variant());
        add(b.cracking.to_variant());
        add(b.crack_hang.to_variant());
        out
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
