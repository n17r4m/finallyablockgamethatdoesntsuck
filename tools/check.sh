#!/usr/bin/env bash
# Runs the headless test suite and reports each result. Exits non-zero on any failure.
#   tools/check.sh         fast tests, about 2 minutes
#   tools/check.sh --full  more seeds, CPU players and longer fuzzing
GODOT="${GODOT:-$(dirname "$0")/../../Godot/Godot_v4.7.2-stable_linux.x86_64}"
GODOT="$(realpath "$GODOT")"
cd "$(dirname "$0")/.."

full=0
[ "$1" = "--full" ] && full=1
failed=0

run() {
	local name="$1"
	shift
	local log start rc
	log="$(mktemp)"
	start=$SECONDS
	"$GODOT" --headless --path . -s "tests/$name.gd" -- "$@" > "$log" 2>&1
	rc=$?
	if [ $rc -eq 0 ] && [ "$(tail -n 1 "$log")" = "PASS" ]; then
		echo "PASS $name ($((SECONDS - start))s)"
	else
		echo "FAIL $name (exit $rc)"
		tail -n 30 "$log"
		failed=1
	fi
	rm -f "$log"
}

run test_sim
run test_touch
run test_netcode
run test_golden
if command -v python3 > /dev/null; then
	if python3 tools/replay_check.py tests/golden > /dev/null; then
		echo "PASS replay_check.py"
	else
		echo "FAIL replay_check.py"
		python3 tools/replay_check.py tests/golden | tail -n 10
		failed=1
	fi
fi
if command -v cargo > /dev/null; then
	log="$(mktemp)"
	start=$SECONDS
	if cargo test --quiet --manifest-path rust/Cargo.toml > "$log" 2>&1; then
		echo "PASS cargo test ($((SECONDS - start))s)"
	else
		echo "FAIL cargo test"
		tail -n 30 "$log"
		failed=1
	fi
	# Fresh games the corpus never saw: Godot plays them, Rust must agree. --full picks new
	# ones every run. A failing game's replay is kept, since it reproduces the difference.
	games=20
	seed=1
	[ $full -eq 1 ] && games=100 && seed=$((RANDOM * 1000 + 1))
	start=$SECONDS
	dir="$(mktemp -d)"
	if "$GODOT" --headless --path . -s tools/make_random_games.gd -- --dir="$dir" --games=$games --seed=$seed --seconds=30 > "$log" 2>&1 \
			&& cargo run --quiet --release --manifest-path rust/Cargo.toml --bin replay_verify -- "$dir" > "$log" 2>&1; then
		echo "PASS Rust matches Godot on $games random games ($((SECONDS - start))s)"
		rm -rf "${dir:?}"
	else
		echo "FAIL Rust and Godot differ, seed $seed, replays kept in $dir"
		grep -v '^ok' "$log" | tail -n 20
		failed=1
	fi
	rm -f "$log"
else
	echo "SKIP Rust checks: no cargo"
fi
if [ $full -eq 1 ]; then
	run test_net_matrix --seeds=8 --cpu=2
	run test_sim_fuzz --minutes=10
	run test_cpu
else
	run test_net_matrix
	run test_sim_fuzz --minutes=1
fi
exit $failed
