#!/usr/bin/env bash
# Capture which native test executable is still alive during long MoonBit runs.
# This does not skip, reorder, or change the timeout of any test.
set -euo pipefail

interval="${MOON_TEST_MONITOR_INTERVAL:-15}"
case "$interval" in
  ''|*[!0-9]*) echo "MOON_TEST_MONITOR_INTERVAL must be an integer" >&2; exit 2 ;;
esac
if (( interval < 1 )); then
  echo "MOON_TEST_MONITOR_INTERVAL must be positive" >&2
  exit 2
fi

monitor() {
  while sleep "$interval"; do
    echo "::group::Moon native test processes at $(date -u +%H:%M:%S) UTC"
    # Show wait channels and wall-clock age, not just CPU usage. A timed
    # wait, socket read, or blocked child should be visible in this snapshot.
    ps -eo pid,ppid,etimes,stat,wchan:24,comm,args |
      awk 'NR == 1 || $6 == "moon" || $6 == "moonrun" || $0 ~ /_build\/native\// || $0 ~ /\/test\/[A-Za-z0-9_.-]+[.]exe/' ||
      true
    echo "::endgroup::"
  done
}

monitor &
monitor_pid=$!
cleanup() {
  kill "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true
}
trap cleanup EXIT

started=$(date +%s)
moon test --target native --output-json
elapsed=$(( $(date +%s) - started ))
echo "Moon native test elapsed: ${elapsed}s"
echo "Moon native test elapsed: ${elapsed}s" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
