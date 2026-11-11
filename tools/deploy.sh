#!/usr/bin/env bash
# Puts the match server and the web game on this machine. See docs/server-admin.md.
#
#   tools/deploy.sh build                 release server + web export, into deploy/out
#   sudo tools/deploy.sh install DOMAIN   once: hands /opt/fbg and /var/www/fbg to you, then
#                                         the server, systemd unit, web files and nginx site
#   tools/deploy.sh update                new server binary and web files, no sudo needed
#   tools/deploy.sh restart               ask the running server to drain and restart onto it
#   tools/deploy.sh console               print how to reach the admin console
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=deploy/out
APP=/opt/fbg
BIN=$APP/fbg-server
WEB=/var/www/fbg
SITE=/etc/nginx/sites-available/fbg
ADMIN=http://127.0.0.1:47111
GODOT="${GODOT:-../Godot/Godot_v4.7.2-stable_linux.x86_64}"

need_built() {
	[ -x "$OUT/fbg-server" ] && [ -f "$OUT/web/index.html" ] || { echo "nothing built: run tools/deploy.sh build first, without sudo" >&2; exit 1; }
}

need_root() {
	[ "$(id -u)" -eq 0 ] || { echo "run this one with sudo" >&2; exit 1; }
	[ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] || { echo "run it with sudo from your own account, which will own the deploy folders" >&2; exit 1; }
	need_built
}

install_files() {
	# The running server keeps the old binary open; the new one takes over on its next start.
	install -m 755 "$OUT/fbg-server" "$BIN.new"
	mv -f "$BIN.new" "$BIN"
	rsync -a --delete "$OUT/web/" "$WEB/"
	echo "installed $BIN and $WEB"
}

case "${1:-}" in
build)
	[ "$(id -u)" -ne 0 ] || { echo "build as yourself, not root" >&2; exit 1; }
	cargo build --release --manifest-path rust/Cargo.toml -p fbg-server
	# The web game runs the Rust rules through this; a stale one would play old rules.
	tools/build_rust_ext.sh web > /dev/null
	rm -rf "$OUT"
	mkdir -p "$OUT/web"
	cp rust/target/release/fbg-server "$OUT/"
	"$GODOT" --headless --path . --export-release "Web" "$OUT/web/index.html" > "$OUT/export.log" 2>&1 \
		|| { tail -n 20 "$OUT/export.log"; echo "web export failed" >&2; exit 1; }
	echo "built into $OUT: $(du -sh "$OUT/web" | cut -f1) of web files"
	;;
install)
	need_root
	domain="${2:?usage: sudo tools/deploy.sh install DOMAIN}"
	# Yours from now on, so updates need no sudo. The server only reads them, as its own user.
	install -d -m 755 -o "$SUDO_USER" -g "$SUDO_USER" "$APP" "$WEB"
	sudo -u "$SUDO_USER" "$0" update --files-only
	install -m 644 deploy/fbg-server.service /etc/systemd/system/fbg-server.service
	systemctl daemon-reload
	systemctl enable --now fbg-server # a changed unit applies at the next restart (tools/deploy.sh restart)
	# certbot adds https to this file, so a rerun leaves it alone. Delete it to start over.
	if [ -e "$SITE" ]; then
		echo "kept $SITE as it is"
	else
		sed "s/DOMAIN/$domain/" deploy/nginx-site.conf > "$SITE"
	fi
	ln -sf "$SITE" /etc/nginx/sites-enabled/fbg
	nginx -t
	systemctl reload nginx
	echo
	echo "Serving http://$domain/ now. For https, which web players need for wss://:"
	echo "  sudo certbot --nginx -d $domain"
	;;
update)
	[ "$(id -u)" -ne 0 ] || { echo "update as yourself, not root" >&2; exit 1; }
	need_built
	[ -w "$APP" ] && [ -w "$WEB" ] || { echo "$APP or $WEB isn't yours: run sudo tools/deploy.sh install DOMAIN once" >&2; exit 1; }
	install_files
	[ "${2:-}" = "--files-only" ] && exit 0
	if ! cmp -s deploy/fbg-server.service /etc/systemd/system/fbg-server.service; then
		echo "deploy/fbg-server.service differs from the installed unit: rerun sudo tools/deploy.sh install DOMAIN to apply it"
	fi
	echo "Web players get the new page on reload. For the server: tools/deploy.sh restart"
	;;
restart)
	curl -fsS -X POST -H 'content-type: application/json' -H 'x-fbg-admin: 1' \
		-d '{"drain":{"on":true,"exit":true}}' "$ADMIN/api/act"
	echo
	echo "It restarts once the games in progress end. Watch it on $ADMIN/"
	;;
console)
	echo "On this machine: $ADMIN/"
	echo "From elsewhere:  ssh -L 47111:127.0.0.1:47111 $(id -un)@$(hostname)  then open http://localhost:47111/"
	;;
*)
	sed -n '2,9p' "$0"
	exit 1
	;;
esac
