# Running the server

How the match server runs on this machine for real players, and how to look after it. Built for
a small start: one process on one host, until about 30 active players. The protocol is in
[server-protocol.md](server-protocol.md), and where this is all heading is in [game-modes.md](game-modes.md).

## The shape of it

```
 player (web, phone, desktop)
   │  https://DOMAIN/        the web game, static files from /var/www/fbg
   │  wss://DOMAIN/ws        the match server
   ▼
 nginx  ── TLS, gzip, X-Real-IP ──▶  fbg-server 127.0.0.1:47110   (systemd: fbg-server)
                                      │  admin console 127.0.0.1:47111, never public
                                      └▶ /var/lib/fbg/fbg.db (SQLite), /var/lib/fbg/replays/
```

Only nginx faces the internet. The server and its console listen on localhost.

## First time

1. Point the domain's DNS at this machine, and forward ports 80 and 443 on the router to it.
2. `tools/deploy.sh build`, as yourself. It builds the server in release and exports the web
   game into `deploy/out`.
3. `sudo tools/deploy.sh install DOMAIN`. It installs `/usr/local/bin/fbg-server`, the systemd
   unit `deploy/fbg-server.service`, the web files, and an nginx site from `deploy/nginx-site.conf`.
4. `sudo certbot --nginx -d DOMAIN`. A page on https can only open `wss://`, so web players need this.
5. Open `https://DOMAIN/`, press Play a friend, and send the link it copies.

Native builds find the server through `[net] server` (Settings, Online), for example
`wss://DOMAIN/ws`, or through `PUBLIC_SERVER` in `autoload/net.gd` once that's filled in.

The service runs as a throwaway user (`DynamicUser`) that can write `/var/lib/fbg` and nothing
else, and systemd starts it again whenever it stops.

## Updating

```
tools/deploy.sh build
sudo tools/deploy.sh update     # swaps the binary and web files; running games aren't touched
tools/deploy.sh restart         # or "Drain & restart" in the console
```

A restart drains first: the server stops starting matches, tells everyone in a game it'll
restart after it, refuses rematches, and stops once the last game ends. systemd starts the new
binary a second later. Web players get the new page when they next load it. A protocol or rules
change refuses older games at the door with a message to update, so update the web files and the
server together.

## The admin console

`http://127.0.0.1:47111/` on this machine. From anywhere else, over ssh:

```
ssh -L 47111:127.0.0.1:47111 you@this-host     then open http://localhost:47111/
```

It shows, live:
- **Matches:** who's playing whom, their pings, how far the referee runs behind the clock, and
  the worst input lateness so far. Watch draws both boards from the referee's copy of the game.
  End stops a match as a draw.
- **Connections:** name, address, platform, where they are (lobby, queue, a room, a match) and ping.
  Kick closes one; if they were playing, the opponent wins. Ban closes every connection from that
  address and refuses it from then on, across restarts.
- **Say something to everyone:** a notice every connected player sees, in the menu or over the match.
- **Drain** stops new matches and **Resume** undoes it. **Drain & restart** stops the server
  once the games in progress end.
- **History:** players per minute over the last day, how matches ended, a histogram of input
  lateness, the last 50 matches with replays to download, bans, and a log of what the admin did.

Ping comes from WebSocket pings the server sends every 2 s. Lateness is how far behind the
server's clock a player's input arrived: the numbers needed before the server can enforce a limit.

### Who can use it

With no password, the console only answers requests addressed to `localhost` or `127.0.0.1`, so
another site can't reach it by pointing a name of its own at this machine. Every action also
needs an `x-fbg-admin` header, which a page on another site can't add, so a link or form can't
fire one. To put it behind a reverse proxy instead, give it a password:
`--admin-password-file FILE` turns on HTTP Basic auth (any user name), and then the host check
no longer applies. Use https for that.

## Flags

| Flag | Default | |
|---|---|---|
| `--listen ADDR:PORT` | `127.0.0.1:47110` | Where games connect |
| `--admin ADDR:PORT` or `--admin off` | `127.0.0.1:47111` | The console |
| `--admin-password-file FILE` | none | Ask for this password, from anywhere |
| `--db FILE` | none | Keep matches, samples, bans and the admin log. Without it, history is empty and bans last until a restart |
| `--replays DIR` | none | Save each match's replay |
| `--trust-proxy` | off | Take the player's address from `X-Real-IP` / `X-Forwarded-For`, only on connections from this machine |
| `--max-connections N` | 4096 | |

## Capacity

Loopback measurements are in [server-protocol.md](server-protocol.md): about 400 matches per
process before delay climbs. Thirty players is about 15 matches, under 10% of one core. The
limit on this host will be the upload bandwidth and the route to players long before the CPU.
The console's lateness histogram and pings are how to see that.

## Not done yet

- **Old replays and samples are never deleted.** Nothing prunes `/var/lib/fbg` yet.
- **The console has no live push.** It polls once a second, and the referee's boards ten times a
  second while watching. That's fine for one admin.
- **Backups:** `sqlite3 /var/lib/fbg/fbg.db ".backup /somewhere/fbg.db"` works while it runs.
