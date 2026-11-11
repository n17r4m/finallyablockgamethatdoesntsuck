# Game modes

Where the game is going past 1v1, and the order it gets built in. Decided 2026-11-10.
Step 0 is built; step 1 is under way.

## The layers

```
 Meta      accounts · season ranks · skins · store · mode-of-the-month rotation
 Modes     "Competitive 2v2" = ruleset preset + format + queue + rating policy
 Lobby     rooms, seats, teams, ready-up, the host edits the ruleset (custom games)
 Server    matchmaking · relay · referee · results · admin console
 Session   rollback for N seats, any mix of local, remote and CPU
 Sim       MatchSpec (seed, ruleset, roster, setup) + inputs -> state
```

Each layer only feeds on the one below. The sim never learns about modes, ranks or skins.

- **Modes are data.** Competitive 1v1/2v2/3v3 is a locked, rated ruleset. Casual is the same
  formats unrated, plus Rumble and the mode of the month. Custom is the host's ruleset, never rated.
- **Skins and the store stay out of the sim.** A cosmetic loadout rides in the roster as
  presentation-only data that is never hashed, and only renderers read it (see the 2D/3D cut-off
  in the README).
- **Results leave the match server as records** (SQLite now, signed later). Ranks and seasons
  read those, so the match server never needs to know about accounts.

## Decisions

**Garbage targeting: all of the above.** Automatic by default (round-robin, the weakest
opponent, or whoever attacked you, chosen by the ruleset). A player can pick a target, which
overrides the automatic one. Garbage can go to a teammate.

**Teams play on separate boards** in standard modes, each player choosing where their garbage goes.

**Rumble is a shared, widened well** with several cursors on it. That makes board width a
variable, which nothing is yet: width 6 is in the touch target encoding and every per-cell
array. It comes after the scalar ruleset.

**A custom ruleset starts as scalars and curves** (decided 2026-11-11): timings, speeds, colours,
garbage tables and toggles. Zero, one or infinity: no number exists because it looked about right.
Every limit the sim enforces (it does, so a custom game can't make the referee's job unbounded) is
a limit of the encoding or of the referee's cost, and it's written down as that. Anything that
varies with something else (raise speed over time, garbage per combo size, garbage per chain
length) is a curve, stored as integer points with integer interpolation, so a later editor can
draw it. Today's tables are those curves' defaults.

**Six colours, six pieces.** The colour count is a ruleset number like any other; the default
stays 5. The sixth colour gets art, and each colour gets a chess piece (pawn, knight, bishop,
rook, queen, king) as a shape for colour-blind play. More than six colours needs more pieces and
moves the garbage cell value off 7.

**Battle royale gets its own coupling.** Full rollback over every board works up to about six
players. Past that, each client owns its board, garbage between boards becomes server-timestamped
events ("at tick T, board k receives a slab"), and the referee checks each board on its own.
`GARBAGE_DELAY` is the latency budget that allows it. So a board must be steppable from its own
inputs plus an incoming garbage stream, which coupled modes feed from inside the sim.

## Order of work

0. **A dedicated server people can actually reach**, with an admin console (see
   [server-admin.md](server-admin.md)). Today's 1v1, on this host, until about 30 active players.
1. **Ruleset as data**, in GDScript and Rust, with replay format 2 carrying it. The default
   ruleset plays today's game exactly. Done so far: the `Rules` data, its bytes and fingerprint
   (`sim/sim_rules.gd`, `rust/sim/src/rules.rs`, the engine contract). Next: the sim reads it
   instead of `SimConst`, then replays and the protocol carry it, then a Rules page.
2. **N boards, teams and routing** in the sim. The P1/P2 mirror fuzz widens to every seat order.
3. **N-seat `RollbackSession`**, including several local seats on one device.
4. **Server rooms** with a host, seats, teams and a validated ruleset.
5. **Lobby and ruleset editor**, and a match layout for N boards.

Then Rumble (variable width), modes and queues, accounts and ranks, battle royale.
