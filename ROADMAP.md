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
| Computer opponent with difficulty levels | 5 personalities × 4 levels, stochastic plan search | done (tuning) |
| Network versus | rollback P2P, ENet/WebSocket | **exceeds** (CA was lockstep TCP) |
| Extreme mode (special blocks/garbage) | — | todo, design our own |
| Sound / music | — | todo |
| Low-detail mode | 2D renderer, GL Compatibility | done |

## Beyond
- **Learned CPU weights.** The CPU's score is a linear model over board features. Next steps, in order:
  1. Self-play tuning: evolve style weight vectors in `tools/league.gd`, keep winners.
  2. Fit a ranking SVM / logistic regression offline on league-logged (features, went-on-to-win)
     pairs; export the weights as a new style. Same dot product at runtime — free and deterministic.
  3. Only if those plateau: a small learned value net (would need inference outside GDScript).
- CPU searches in the ring: `stochastic`, `beam`, `flatmc` (see ai/cpu_player.gd). First ring
  (30 games, hard): beam 1548, flatmc 1524, stochastic 1428 (Bradley-Terry); beam vs stochastic
  8-2, CI still touches 50%. Open question: why noise helps so much (noise 0 loses 20-0; a flat
  eagerness bonus doesn't replace it). The data march includes noise variants to map it.
- Data march: `tools/league.gd --positions` logs (own features, opponent features, outcome) once
  a second; `tools/league_report.py` gives Wilson CIs + ratings. Feeds step 2 above.
- Demo/attract mode exists (`--demo`); use it for trailers and the title screen.
- Rollback netcode with desync detection (done), spectators, replays (inputs are already a tiny log).
- Matchmaking + ranking (droplix plans: signaling server, Elo).
- Web, mobile and console builds from one codebase.
- Touch controls (drag to swap).
- Puzzle mode (the sim already supports hand-placed boards via `SimBoard.put`).
- Accessibility: colour-blind palettes / shape glyphs per colour, remappable controls.
- Difficulty levels scaling hover/flash/rise like Panel de Pon levels.
