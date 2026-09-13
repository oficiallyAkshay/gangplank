#!/usr/bin/env bash
# tests/run.sh — runs every tests/*.test.sh in a fresh subshell (its own
# bash process), prints one line per test, a final tally, and exits
# non-zero on any failure.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."

total_files=0
failed_files=0
not_yet_runnable=0

for f in tests/*.test.sh; do
  [ -e "$f" ] || continue
  total_files=$((total_files + 1))
  echo "== $f =="
  output="$(bash "$f" 2>&1)"
  ec=$?
  printf '%s\n' "$output"
  if printf '%s' "$output" | grep -q '^SKIP - '; then
    not_yet_runnable=$((not_yet_runnable + 1))
  elif [ "$ec" -ne 0 ]; then
    failed_files=$((failed_files + 1))
    echo "FAIL: $f (exit $ec)"
  fi
  echo
done

echo "---"
echo "$total_files test file(s), $failed_files failed, $not_yet_runnable not yet runnable"

[ "$failed_files" -eq 0 ]
