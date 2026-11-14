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
- **Whether versions match.** A different protocol, engine version or tick rate is refused at
  the door, with a reason the player can read.
- **What rules a match plays by.** Standard, or a room host's, checked before anyone plays.
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
| Left | A player's connection closed (a game without resume, or after the game), or it flooded the server | The other team wins |
| Stalled | A player's inputs stopped for 10 s while it held the match up | The other team wins |
| Wrong state | A player's hash differs from the referee's | The other team wins, or a draw if more than one player differs |
| Bad input | An impossible message: bits outside the input mask, a change past its own frontier, a frontier over 2 s past the server's clock, or a hash that can't exist | The other team wins |
| Too long | Two hours of game | A draw |
| Ended | Whoever runs the server ended it from the admin console | A draw |

"The other team" is the other player in a 1v1. With more than two teams there's no saying who
would have won, so a match that ends against one player is a draw among the rest.

A match that falls behind the server's clock is not stalled. Clients drop ticks after a hitch
and never bank them, so an honest match can run late for good. Only a frontier that has stopped
moving counts, and the blame goes to whichever player is further behind, because the other one
runs out of room to predict shortly after and stops through no fault of its own.

**A dropped connection** from a game that can resume doesn't end the match. The server holds
the seat, tells the other player (Away), and the match waits as it would for a slow
connection. A new connection whose hello carries the seat's token from the start takes the seat
back. If the old connection is still open on the server (a phone that changed networks leaves
one behind), the server closes it. The match then carries on: each side's session resends what
the other hasn't acknowledged. A player who doesn't return within the stall limit loses as
Stalled, and the other player goes back to the lobby.

## Messages

Protocol 3. The code is `rust/proto` (`fbg-proto`): the server uses it directly, and the game
through the Godot extension (`FbgWire`, behind `net/server_link.gd`), so both ends run the same
code. A build without the extension can't play online.

One binary WebSocket frame is one message: a message number (varint), then the message's
fields in protobuf's wire encoding. Each field is a tag (field number << 3 | wire type) and a
value; protobuf's own tools can read a message's fields (`protoc --decode_raw`, after the first
byte). A field left out is 0, empty or false, and zeros aren't written.

**How it grows.** A reader skips fields and messages it doesn't know, so adding either is never
a break: an older game ignores what's new, and a newer one finds it missing. What each side can
do beyond the core is in `features`, a bit set in the hello and the welcome, and neither sends
what the other didn't say it understands. Changing what a field means, or taking one away, is a
new protocol number, and the server refuses other numbers with a request to update.

**Damage** (a length past the end, a wire type that can't be, a limit broken) closes the
connection. So does anything before a hello. An unknown message is ignored.

Types: **uint** varint; **sint** zigzag varint; **fixed64** 8 bytes, for seeds and hashes;
**bytes**/**text** length-prefixed, text UTF-8. Field numbers in brackets.

**Game to server**

| # | Message | Fields |
|---|---|---|
| 1 | Hello | protocol [1], engine [2] (`RULES_VERSION`), tick rate [3], name [4] (text, up to 24 bytes), platform [5] (up to 16 bytes of letters, digits, `.` and `_`), features [6], resume [7] (a start's 16-byte token, to take that seat back) |
| 2 | Quick match | mode [1]: 0 is standard 1v1, the only one so far |
| 3 | Room | code [1] (1-16 ASCII letters and digits, case ignored), rules [2] (a ruleset's bytes; empty for standard), teams [3] (a byte per seat, its team; empty for a 1v1) |
| 4 | Input | see below |
| 5 | Rematch | |
| 6 | Ping | time [1] |

**Server to game**

| # | Message | Fields |
|---|---|---|
| 16 | Welcome | features [1], resumed [2]: the match the hello's token got this player back into, or 0 |
| 17 | Refused | code [1]: 0 other, 1 update, 2 draining, 3 banned, 4 full, 5 bad rules; text [2]. The connection then closes |
| 18 | Waiting | room [1], empty in the queue; here [2] of the room's seats [3] are taken. Sent again to everyone in the room when that changes |
| 19 | Start | match id [1], seed [2] fixed64, your seat [3], rules [4] (empty: standard), seats [5], repeated: each a message of name [1], team [2], platform [3]; resume [6], this seat's 16-byte token |
| 20 | Input | the same as the game's, with seat [1] saying whose |
| 21 | Result | winner [1] (a team: in a 1v1, the seat), reason [2] (the table above, in order), tick [3] sint, draw [4] |
| 22 | Pong | time [1], from the ping |
| 23 | Left | seat [1]: that player left after the game, and this one is back in the lobby |
| 24 | Notice | text [1], up to 200 bytes: from whoever runs the server, to show the player |
| 25 | Away | seat [1], away [2]: that seat's connection dropped and the match is waiting (true), or it's back (false) |

**Features**: bit 0, custom rules; bit 1, resume (see above); bit 2, seats: plays matches of
more than two (reads and sends acks [10]).

**Rooms.** A room's first player hosts it, and the host's rules and teams are the match's. The
teams are each seat's team, numbered from 0, every team with a seat and at least two teams, two
to eight seats (`fbg_sim`'s `MAX_SEATS`, the cost of rolling back every board). Seats go in the
order players arrive, so the host is seat 0. The match starts once every seat is taken; until
then whoever leaves the room frees their place, and the room lasts while anyone is in it. A
game that didn't say it can play more than two isn't let into a bigger room. Every input is
relayed to every other seat, and Away and Left go to everyone else. A rematch starts once every
seat has asked for one.

The host's rules are the
match's; the server checks them with the same code the sims run (`Rules::decode`) and turns away
anything that isn't a playable ruleset. A game that didn't say it can play custom rules is told
it can't join such a room, and stays in the lobby. Rematches keep the rules.

**Input**, both ways: seat [1] uint, frontier [2] sint, then relative to the frontier: acknowledged
[3] sint, the sender's tick [4] sint; advantage [5] sint; change ticks [6] packed sint, each from
the one before (the first from the frontier); change masks [7] packed uint (32 bits); check ticks
[8] packed sint, the same way; check hashes [9] packed fixed64; acks [10] packed sint, with more
than two seats: per seat, the newest change of that seat's the sender has seen, each from the one
before (the first from the frontier), so [3] is only a 1v1's. Up to 256 changes and 16 checks,
and ticks and masks pair up. These mean what they mean in `sim/rollback_session.gd`. A typical
input is about 17 bytes, against 47 in protocol 2, and reading one allocates nothing.

**Text**: the server cuts names to 24 bytes on a character boundary, drops control characters,
and calls an empty name "Player".

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
- **Replays pile up** in `--replays` with nothing clearing them, and a match on custom rules
  isn't saved at all yet: replay files can't hold a ruleset.
