# Roadmap

The bar: **exceed Crack Attack** in every dimension it had, then go past it.
Crack Attack is GPL code we don't own — we match its *behaviour*, clean-room. Never port its
code or assets (see CONTRIBUTING.md); that would break dual licensing.

Feature list below is from memory of Crack Attack; correct it where it's wrong.

## Parity
| Crack Attack | Us | Status |
|---|---|---|
| Panel de Pon rules: swap, gravity, combos, chains | per-panel state machine, 1080 Hz | done |
| Garbage: combo slabs, chain slabs, shatter into panels | multi-row slabs, flash + convert | done (plain FX) |
| 3D rendered blocks, lit, animated | BoardRenderer3D over BoardView | first pass |
| Combo / chain signs | callouts | basic |
| Countdown, win / lose screens | in-sim countdown, winner, rematch | done |
| Top-out grace ("dying") with warning | health timer + danger shake | done |
| Solo mode with score + high-score table | practice (solo sim) | score yes, table no |
| Computer opponent with difficulty levels | — | todo |
| Network versus | rollback P2P, ENet/WebSocket | **exceeds** (CA was lockstep TCP) |
| Extreme mode (special blocks/garbage) | — | todo, design our own |
| Sound / music | — | todo |
| Low-detail mode | 2D renderer, GL Compatibility | done |

## Beyond
- Rollback netcode with desync detection (done), spectators, replays (inputs are already a tiny log).
- Matchmaking + ranking (droplix plans: signaling server, Elo).
- Web, mobile and console builds from one codebase.
- Touch controls (drag to swap).
- Puzzle mode (the sim already supports hand-placed boards via `SimBoard.put`).
- Accessibility: colour-blind palettes / shape glyphs per colour, remappable controls.
- Difficulty levels scaling hover/flash/rise like Panel de Pon levels.
