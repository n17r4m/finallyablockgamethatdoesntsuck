# Engine contract

What a second implementation of the sim (a Rust port, a server-side referee) has to match
exactly. If the code and this document disagree, one of them has a bug.

The rule of the contract: **given a seed, a setup and a list of inputs, every implementation
produces the same state, byte for byte, on every tick.**

- **The rules** are defined by `sim/sim_board.gd` and `sim/sim_state.gd`, and locked by the
  recorded games in `tests/golden/`. When GDScript and Rust disagree, GDScript is right for now.
- **`tools/replay_check.py`** reads the formats below using only this document, without Godot.
- **`rust/sim`** is a second implementation of the rules, held to the same recorded games, plus
  fresh random ones from `tools/make_random_games.gd`.

## Versions

| Value | Where | Change it when |
|---|---|---|
| `RULES_VERSION` | `SimConst` | Anything changes what a game does: a rule, a timing, the state hash |
| `TICK_HZ` | `SimConst` | The tick rate changes (720 now) |
| `FORMAT` | `Replay` | The replay byte layout changes |

A replay only verifies on a build with the same rules version and tick rate.

### Changing a rule on purpose

`tests/test_golden.gd` fails on any change to what a game does, which is its job.

1. Make the change in `sim/` and in `rust/sim/`, and bump `RULES_VERSION` in both.
2. Run `godot --headless --path . -s tools/make_golden.gd`.
3. Run `tools/check.sh`, and say in the commit that the rules changed.

Replays from older rules stop verifying. Playing them back would need the old build.

## All numbers

Little-endian. Signed integers are two's complement.

## State hash

The first 8 bytes of the SHA-256 of the state's canonical bytes.

### Canonical state bytes

| Field | Encoding |
|---|---|
| `tick` | i64 |
| `solo` | u8, 0 or 1 |
| `winner` | i64: -1 playing, 0 or 1 that board won, 2 draw |
| board 0 | see below |
| board 1 | see below |

Each board is written field by field, in the order of `SimBoard.STATE`:

| Field | Type | Field | Type |
|---|---|---|---|
| `color` | bytes | `busy` | bool |
| `st` | bytes | `need_scan` | bool |
| `tm` | i32s | `need_support` | bool |
| `aux` | i32s | `has_matched` | bool |
| `chain` | bytes | `chain_n` | int |
| `gid` | i32s | `outbox` | i32s |
| `reveal` | bytes | `gar_q` | i32s |
| `next_row` | bytes | `gar_t` | int |
| `cursor_x` | int | `gar_side` | int |
| `cursor_y` | int | `next_gid` | int |
| `prev_input` | int | `fx_combo` | int |
| `hold` | int | `fx_chain` | int |
| `rise` | int | `fx_t` | int |
| `stop_t` | int | `age` | int |
| `health` | int | `sent` | int |
| `rng` | int | `best_chain` | int |
| `score` | int | `swaps` | int |
| `lost` | bool | `time_rate` | int |
| | | `world_acc` | int |
| | | `ramp_t` | int |
| | | `cracking` | bool |
| | | `crack_hang` | int |

(Read the left column top to bottom, then the right.)

- **bool:** u8, 0 or 1.
- **int:** i64.
- **bytes:** u32 element count, then the bytes.
- **i32s:** u32 element count, then each element as i32.

Per-cell arrays hold `6 x 24 = 144` elements, row by row, with row 0 at the top of the hidden
buffer. `next_row` holds 6.

The hash deliberately covers presentation and stats fields (`fx_*`, `sent`, `swaps` and so on)
as well, so an implementation that gets them wrong is caught immediately.

`tests/golden/vectors.json` gives the exact bytes and hash for a few real states. Those are
the place to start debugging a serializer, since they don't need a working sim.

## Replay file (`.fbgr`)

| Field | Encoding | Notes |
|---|---|---|
| magic | 4 bytes | `FBGR` |
| format | u8 | 1 |
| rules | u16 | `RULES_VERSION` |
| tick rate | u16 | `TICK_HZ` |
| flags | u8 | bit 0: solo. Other bits must be 0 |
| seed | i64 | |
| end tick | varint | The game runs for ticks `0 .. end - 1`. At most 2 hours |
| start hash | 8 bytes | State hash after setup, before any tick |
| setup | count, then ops | Applied in order to the new state |
| player 0 inputs | count, then events | |
| player 1 inputs | count, then events | |
| checkpoints | count, then entries | At least one |
| trailer | 8 bytes | First 8 bytes of the SHA-256 of everything before it |

**Varint:** unsigned LEB128, at most 8 bytes (56 bits), with no redundant trailing zero byte.

**Counts:** a count larger than the bytes left in the file is refused, before anything is read.

**Setup op:** op u8, board u8, then its arguments, one u8 each:

| Op | Name | Arguments | Meaning |
|---|---|---|---|
| 0 | clear | none | `clear_all()` |
| 1 | put | x, row, colour | `put()`: x is 0 to 5, row is 0 to 23 with 0 the bottom visible row, colour is 0 to 5 |
| 2 | garbage | width, height | `receive_garbage()` with one slab: width is 1 to 6, height is 1 to 12 |

Anything else, including a board other than 0 or 1, is refused.

Real matches have no setup. It exists for hand-built boards and, later, puzzle mode.

**Input event:** tick delta varint, mask varint. A player's input at tick `t` is the mask of
the last event at or before `t`, or 0 if there isn't one. The first delta counts from -1, so
a first event on tick 0 has a delta of 1. Every delta is at least 1, and every event is before
the end tick. Masks may only use `SimConst.INPUT_BITS`.

Events can land on any tick, not just frame boundaries, so finer input timestamps won't need
a format change.

**Checkpoint:** tick delta varint, then the state hash after stepping to that tick. The first
delta counts from 0, and every delta is at least 1. None may pass the end tick, and the last
one must be on it.

The trailer catches damage, not forgery, because anyone can recompute it. What stops a forged
game is re-simulating it.

## Verifying a replay

1. Refuse the file if its trailer, layout or limits are wrong.
2. Refuse it if its rules version or tick rate differ from this build's.
3. Create the state from the seed, apply the setup, and compare the start hash.
4. For each tick from 0 to end - 1: step with both players' inputs at that tick. If a
   checkpoint is at the new tick number, compare its hash.

Report the first checkpoint that differs. In a port, that second of the game holds the first
bug, and the replay can be stepped tick by tick from there.

## Order of operations in one tick

`SimState.step(input0, input1)`:

1. If there's already a winner, only `tick` advances.
2. Step board 0, then board 1, unless solo. Before the countdown ends, a board only moves its
   cursor.
3. Each board's `outbox` goes to the other board, board 0's first. In solo it's thrown away.
4. Set `winner`. If both boards lost on the same tick, it's a draw.
5. `tick` advances.

Neither board can see the other's step, so player order doesn't affect the result.
`tests/test_sim_fuzz.gd` checks this by swapping the players.

## What isn't in the contract

- Rendering, audio and input devices. They read the state and never write to it.
- The network packet format, which will change when the server arrives.
- Which player's machine ran what, and when. `RollbackSession` timing never affects the state.
