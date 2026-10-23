# Finally A Block Game That Doesn't Suck

Panel-de-Pon-style 1v1 versus, Godot 4.7, pure GDScript, rollback netcode.

## Run
- Editor: open `project.godot` with `../Godot/Godot_v4.7.2-stable_linux.x86_64`.
- Two local clients: `tools/duo.sh` (host + join on 127.0.0.1).
- Launch args (after `--`): `--host`, `--join=ADDR`, `--practice`.
- Netcode soak test: `godot --headless --path . -s tests/test_netcode.gd` (must print PASS).

## Layout
- `sim/` — deterministic game. **Integer-only, no nodes, no floats, no engine RNG.** 1080 Hz fixed tick.
- `sim/rollback_session.gd` — input delay + rollback; inputs are (tick, mask) change events; checksums exchanged each second.
- `autoload/` — Config (user://settings.cfg) → Controls (bindings) → Net (ENet / WebSocket, 1v1 handshake) → Scenes.
- `scenes/` — boot → title/lobby → match. Match drives the session off the wall clock and draws with `_draw`.

## Rules for sim code
Anything that affects gameplay goes in `sim/` and must be reproducible from (seed, inputs).
Rendering reads `session.state`; it never writes to it. Run the soak test after any sim change.
