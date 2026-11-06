# Finally A Block Game That Doesn't Suck

Panel-de-Pon-style 1v1 versus, Godot 4.7, GDScript, rollback netcode. The game plays on a Rust copy of the rules wherever its extension loads, and on the GDScript ones otherwise; both are held to the same recorded games, and can play each other online. The rest of the game is GDScript.

## Run
- Editor: open `project.godot` with `../Godot/Godot_v4.7.2-stable_linux.x86_64`.
- Two local clients: `tools/duo.sh` (host + join on 127.0.0.1).
- Launch args (after `--`): `--host`, `--join=ADDR`, `--practice` (endless solo),
  `--cpu=NAME[:LEVEL]` (e.g. `--cpu=Architect:hard`), `--demo[=NAME[:LEVEL]]` (CPU vs CPU, loops).
- Controls: keyboard (arrows/WASD, space/X swap, C/shift raise), gamepad (d-pad or left stick, A/B, shoulders), and
  touch/mouse: tap between two blocks to swap them, drag a block sideways to carry it, hold the rising row to raise. A mouse floating over the board also carries the cursor with it, centred on the pointer, until a direction key or button takes over.
  Leave a match with esc, start, the Leave button or Android's back: during play each asks "Sure?" first. Back also quits from the title. Hints are for whichever input you used last.
- Cursor style (Settings, experimental): the default two-block swap cursor, or a one-block grab cursor. Press on a block, move to carry it along its row, and let go; keys and pads hold the swap button to grab. It turns into the same placements and swaps, so it can't affect the sim, replays or the server.
- Settings: the title's Settings button covers display, sound levels, key and gamepad bindings, and touch timing. Everything saves to `user://settings.cfg` as it changes. Bindings only decide which key makes which input bit, so they can't affect the sim or replays. Tests and tools (`godot -s`) start from the defaults and never touch this file.
- Record footage: `godot --path . --write-movie out.avi --fixed-fps 60 -- --practice` (sim follows movie time).
- Tests: `tools/check.sh` (about 2 minutes), or `tools/check.sh --full` for more seeds, CPU players and longer fuzzing. Set `GODOT` to use a
  different engine binary. Each test prints PASS and can also run alone with `godot --headless --path . -s tests/NAME.gd`:
  `test_sim` (game rules), `test_touch` (touch controls), `test_grab` (the one-block grab cursor), `test_any_input` (hints follow the last input used, Leave and retry on every device, hint placement, buttons per platform), `test_keys` (short key and button presses reach the sim), `test_title` (title menu layout), `test_settings` (settings menu, rebinding, saved settings), `test_leave` (leaving a match by touch and Android's back), `test_match_layout` (boards on screen and touch mapping at phone and desktop shapes), `test_golden` (recorded games still play out exactly), `test_netcode` (lossy-link rollback soak), `test_net_matrix` (freezes, spikes, blackouts,
  lopsided routes and fairness), `test_sim_fuzz` (board invariants, snapshots, P1/P2 mirror), `test_cpu` (CPU sanity, slow).
- Replays: every real match saves to `user://replays` (`[replay] save` and `keep` in settings). Inspect one with `python3 tools/replay_check.py FILE`, or re-simulate it with `godot --headless --path . -s tools/replay_verify.gd -- FILE`.
- Rust rules (needs `cargo`, which `tools/check.sh` skips if missing): `cd rust && cargo test`. Verify replays with `cargo run --release --bin replay_verify -- FILE_OR_DIR`, or time the rules with `cargo run --release --bin bench_sim -- ../tests/golden/cpu_1.fbgr`.
- Changed a rule on purpose? See [docs/engine-contract.md](docs/engine-contract.md), which also specifies the state hash and replay format.
- Fresh random games for testing another implementation: `godot --headless --path . -s tools/make_random_games.gd -- --dir=DIR --games=N`.
- Sim cost on busy boards: `godot --headless --path . -s tools/bench_sim.gd`, on an idle machine.
- CPU league (logs to `data/`, gitignored): `nice -n 19 godot --headless --path . -s tools/league.gd --
  --agents=beam/balanced/hard,flatmc/chainer/hard,Architect:max --games=10 --out=data/run1 [--positions]`,
  then `python3 tools/league_report.py data/run1`.

## Layout
- `sim/` — the game. Integer-only, no nodes, no floats, no engine RNG, 720 Hz fixed tick.
  `sim_board.gd` is Panel de Pon on a 6x(12+12 hidden) grid: every cell runs a state machine
  (swap / hover / fall / land / matched) on tick timers; chains, combos and garbage live here.
- `sim/rollback_session.gd` — input delay + rollback; inputs are (tick, mask) change events; checksums exchanged each second;
  time sync keeps rollbacks even by slowing whichever side runs further ahead of the other's inputs.
- `sim/replay.gd` — a whole game as data: seed, setup, inputs and state hashes. Verifies by re-simulating.
- `rust/sim/` — the same rules in Rust, for the server and for faster clients. `board.rs` follows `sim_board.gd` function by function.
- `rust/server/`, `net/server_link.gd` — the match server and the game's end of it: pairs players, relays inputs, referees on the real rules. See [docs/server-protocol.md](docs/server-protocol.md).
- `rust/godot/`, `ext/` — the Godot extension that exposes those rules as `RustSim`, which `sim/rust_state.gd` wraps for the game. `[sim] backend` in settings is `auto` or `gdscript`. Build it with `tools/build_rust_ext.sh`; see [docs/platforms.md](docs/platforms.md).
- `ai/cpu_player.gd` — CPU opponents: stochastic plan search on a settled-board model; personalities × levels.
- `view/board_view.gd` — **the 2D→3D cut-off** (below).
- `render/` — renderers that read only BoardView. `board_renderer_2d.gd` is placeholder art.
- `autoload/` — Config (user://settings.cfg) → Controls (bindings) → Net (ENet / WebSocket, 1v1 handshake) → Scenes.
- `scenes/` — boot → title/lobby (with the settings menu over it) → match. Match drives the session off the wall clock.

## The 2D→3D cut-off
Gameplay is, and stays, a 2D grid. The only third dimension in a block game is presentational:
the swap arc (one panel passes in front of the other), pop bursts toward the camera, landing squash.

`BoardView` is the single line between the two worlds. It turns integer states/timers into a
`Vector3` position (+ scale, flash, pop progress) per block. Everything float or spatial lives on
the view side; the sim never learns where anything is drawn and must never depend on depth.

Moving to 3D therefore means writing `render/board_renderer_3d.gd` (e.g. a MultiMesh fed
`pos`/`scale`), swapping it in `scenes/match.gd:_ready`, and changing the renderer to Forward+/Mobile
if needed. No sim, netcode or test changes. Because the sim ticks at 720 Hz, view positions are
already smooth at any display rate — no interpolation layer required.

## Rules for sim code
Anything that affects gameplay goes in `sim/` and must be reproducible from (seed, inputs).
Rendering reads `session.state`; it never writes to it. Run the soak test after any sim change.
