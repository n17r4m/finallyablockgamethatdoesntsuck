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
if [ $full -eq 1 ]; then
	run test_net_matrix --seeds=8 --cpu=2
	run test_sim_fuzz --minutes=10
	run test_cpu
else
	run test_net_matrix
	run test_sim_fuzz --minutes=1
fi
exit $failed
