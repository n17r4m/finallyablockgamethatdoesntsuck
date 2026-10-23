# Finally A Block Game That Doesn't Suck

Panel-de-Pon-style 1v1 versus, Godot 4.7, pure GDScript, rollback netcode.

## Run
- Editor: open `project.godot` with `../Godot/Godot_v4.7.2-stable_linux.x86_64`.
- Two local clients: `tools/duo.sh` (host + join on 127.0.0.1).
- Launch args (after `--`): `--host`, `--join=ADDR`, `--practice` (endless solo),
  `--cpu=NAME[:LEVEL]` (e.g. `--cpu=Architect:hard`), `--demo[=NAME[:LEVEL]]` (CPU vs CPU, loops).
- Renderer: `[video] renderer="3d"` (default) or `"2d"` in `user://settings.cfg`.
- Record footage: `godot --path . --write-movie out.avi --fixed-fps 60 -- --practice` (sim follows movie time).
- Tests (both must print PASS): `godot --headless --path . -s tests/test_sim.gd` (game rules) `-s tests/test_netcode.gd` (lossy-link rollback soak), `-s tests/test_cpu.gd` (CPU sanity, slow).
- CPU league: `godot --headless --path . -s tools/league.gd -- hard 6`.

## Layout
- `sim/` — the game. Integer-only, no nodes, no floats, no engine RNG, 1080 Hz fixed tick.
  `sim_board.gd` is Panel de Pon on a 6x(12+12 hidden) grid: every cell runs a state machine
  (swap / hover / fall / land / matched) on tick timers; chains, combos and garbage live here.
- `sim/rollback_session.gd` — input delay + rollback; inputs are (tick, mask) change events; checksums exchanged each second.
- `ai/cpu_player.gd` — CPU opponents: stochastic plan search on a settled-board model; personalities × levels.
- `view/board_view.gd` — **the 2D→3D cut-off** (below).
- `render/` — renderers that read only BoardView. `board_renderer_2d.gd` is placeholder art.
- `autoload/` — Config (user://settings.cfg) → Controls (bindings) → Net (ENet / WebSocket, 1v1 handshake) → Scenes.
- `scenes/` — boot → title/lobby → match. Match drives the session off the wall clock.

## The 2D→3D cut-off
Gameplay is, and stays, a 2D grid. The only third dimension in a block game is presentational:
the swap arc (one panel passes in front of the other), pop bursts toward the camera, landing squash.

`BoardView` is the single line between the two worlds. It turns integer states/timers into a
`Vector3` position (+ scale, flash, pop progress) per block. Everything float or spatial lives on
the view side; the sim never learns where anything is drawn and must never depend on depth.

Moving to 3D therefore means writing `render/board_renderer_3d.gd` (e.g. a MultiMesh fed
`pos`/`scale`), swapping it in `scenes/match.gd:_ready`, and changing the renderer to Forward+/Mobile
if needed. No sim, netcode or test changes. Because the sim ticks at 1080 Hz, view positions are
already smooth at any display rate — no interpolation layer required.

## Rules for sim code
Anything that affects gameplay goes in `sim/` and must be reproducible from (seed, inputs).
Rendering reads `session.state`; it never writes to it. Run the soak test after any sim change.
