# The match server

`rust/server` pairs players, relays their inputs and referees their matches. It's how the
internet plays. LAN play stays direct over ENet (`Net.host`, `Net.join`) and never touches it.

Run it with `cargo run --release -p fbg-server -- --listen 0.0.0.0:47110 --replays DIR`, from
`rust/`. It listens on localhost unless told otherwise. A game served over https can only reach
`wss://`, so in production it belongs behind a reverse proxy that handles TLS.

A game joins with `--server=ws://HOST:47110 [--room=CODE]`, or on the web with
`?server=wss://HOST&room=CODE` in the page address. No room means quick match. The title's
Quick match and Play a friend buttons use `[net] server` from settings, or on the web the
page's own host at `/ws`. A web page opened with only `?room=CODE` joins that room there,
which is what an invite link is.

Running it for real, with its admin console: [server-admin.md](server-admin.md).

## What it decides

- **Who plays whom.** The first two in the queue, or the two with the same room code.
- **The seed.** Neither player gets to choose a board they've practised.
- **Whether versions match.** A different protocol, rule version or tick rate is refused at the
  door, with a reason the player can read.
- **What each player sees of the other.** Everything goes through the server, so a player can't
  tell the two ends different things, and a message that breaks the rules is never passed on.
- **The result.** The referee plays the match on `rust/sim` from the inputs it relays. It runs
  up to the tick both players have made final, so it never predicts or rolls back.

Players still run rollback exactly as they do over LAN. `RollbackSession` doesn't know the server
exists: `net/server_link.gd` turns its packets to and from these bytes.

## How a match can end

| Reason | What happened | Result |
|---|---|---|
| Played | The rules ended the game | Whoever the referee says won |
| Left | A player's connection closed, or it flooded the server | The other player wins |
| Stalled | A player's inputs stopped for 10 s while it held the match up | The other player wins |
| Wrong state | A player's hash differs from the referee's | The other player wins, or a draw if both differ |
| Bad input | An impossible message: bits outside the input mask, a change past its own frontier, a frontier over 2 s past the server's clock, or a hash that can't exist | The other player wins |
| Too long | Two hours of game | A draw |
| Ended | Whoever runs the server ended it from the admin console | A draw |

A match that falls behind the server's clock is not stalled. Clients drop ticks after a hitch
and never bank them, so an honest match can run late for good. Only a frontier that has stopped
moving counts, and the blame goes to whichever player is further behind, because the other one
runs out of room to predict shortly after and stops through no fault of its own.

## Messages

One binary WebSocket frame is one message, little-endian, with the first byte saying which.
Anything malformed closes the connection. So does anything before a hello.

**Game to server**

| Byte | Message | Then |
|---|---|---|
| 1 | Hello | protocol u16, rules u16, tick rate u16, name (text, up to 24 bytes), platform (text, up to 16 bytes of letters, digits, `.` and `_`) |
| 2 | Quick match | |
| 3 | Room | length u8 (1-16), code (ASCII letters and digits, case ignored) |
| 4 | Input | see below |
| 5 | Rematch | |
| 6 | Ping | any 8 bytes |

**Server to game**

| Byte | Message | Then |
|---|---|---|
| 64 | Welcome | |
| 65 | Refused | length u8, reason (UTF-8). The connection then closes |
| 66 | Waiting | |
| 67 | Start | match id u64, seed i64, seat u8, the opponent's name (text) |
| 68 | Input | see below, the other player's |
| 69 | Result | winner u8 (0, 1, or 2 for a draw), reason u8 (the table above, in order), tick i64 |
| 70 | Pong | the 8 bytes from the ping |
| 71 | Opponent left | The player is back in the lobby |
| 72 | Notice | text, up to 200 bytes: a message from whoever runs the server, to show the player |

**Text** is a length u8 then that many bytes of UTF-8. The server cuts names to 24 bytes on a
character boundary, drops control characters, and calls an empty name "Player". A protocol 1
hello (no name or platform) still decodes, so an old game is told to update rather than dropped.

**Input**, the same both ways: frontier i64, acknowledged i64, sender's tick i64, advantage i64,
change count u16 (up to 256), then for each change tick i64 and mask i32, then hash count u8 (up
to 16), then for each hash tick i64 and hash i64. These mean what they mean in
`sim/rollback_session.gd`.

## Measured

Match server and load generator (`load_test`) sharing one 16-thread desktop, on loopback, with
every match relaying 120 messages a second and refereeing a recorded CPU game:

| Matches | Delay added, typical | p99 | Worst | Server CPU | Peak memory |
|---|---|---|---|---|---|
| 10 | 0.10 ms | 0.18 ms | 2.7 ms | 7% of a core | 6 MB |
| 200 | 0.24 ms | 1.0 ms | 6.6 ms | 145% | 65 MB |
| 400 | 0.57 ms | 2.4 ms | 10.7 ms | 315% | 127 MB |
| 600 | 1.9 ms | 39 ms | 77 ms | 499% | 188 MB |
| 800 | 93 ms | 174 ms | 238 ms | 515% | 249 MB |

So plan on about 400 matches per process for now. Past that, delay climbs fast with nothing to
warn about it. All matches share one task, which is the limit to lift first.

## What this doesn't do yet

- **Packet loss stalls everyone behind it.** WebSocket runs on TCP, so one lost packet holds up
  the ones after it. That's the price of having one transport on every platform. Native clients
  should get UDP carrying these same messages, and web clients WebRTC.
- **A player can hold back inputs for an edge.** The server records how late each player's
  inputs arrive, and logs the worst, but doesn't enforce a limit. A limit needs real numbers from
  real routes, or it punishes bad connections instead of cheats.
- **A player can lie about its advantage,** which steers who slows down to even out rollbacks.
  It's relayed as sent. The server has the clock to measure this itself, and should.
- **It doesn't stop a player using a bot,** or reading its own game's memory. It proves what
  happened under the rules, not who pressed the buttons.
- **There are no accounts, ranks or matchmaking by skill,** and a room code is only as private
  as whoever you tell it to. Names are whatever the player typed.
- **Replays pile up** in `--replays` with nothing clearing them.
