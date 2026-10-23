#!/usr/bin/env bash
# Launch a host and a joining client side by side for local netplay testing.
GODOT="${GODOT:-$(dirname "$0")/../../Godot/Godot_v4.7.2-stable_linux.x86_64}"
cd "$(dirname "$0")/.."
"$GODOT" --path . --position 0,40 -- --host &
sleep 1
"$GODOT" --path . --position 700,40 -- --join=127.0.0.1 &
wait
