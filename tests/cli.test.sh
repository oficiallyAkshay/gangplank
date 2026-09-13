#!/usr/bin/env bash
# tests/cli.test.sh — bin/gangplank: --help and an unknown verb.

set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
CLI="$REPO_ROOT/bin/gangplank"
require_script "$CLI"

out="$(mktemp)"; err="$(mktemp)"
bash "$CLI" --help >"$out" 2>"$err"
ec=$?
help_out="$(cat "$out")"
rm -f "$out" "$err"
assert_exit 0 "$ec" "--help: exits 0"
assert_contains "$help_out" "install" "--help: mentions the install verb"
assert_contains "$help_out" "status" "--help: mentions the status verb"
assert_contains "$help_out" "dry-run" "--help: mentions the dry-run verb"
assert_contains "$help_out" "uninstall" "--help: mentions the uninstall verb"

out="$(mktemp)"; err="$(mktemp)"
bash "$CLI" bogus-verb >"$out" 2>"$err"
ec=$?
bogus_err="$(cat "$err")"
rm -f "$out" "$err"
assert_exit 64 "$ec" "unknown verb: exits 64"
assert_contains "$bogus_err" "unknown verb" "unknown verb: clear line naming the problem"

out="$(mktemp)"; err="$(mktemp)"
bash "$CLI" >"$out" 2>"$err"
ec=$?
rm -f "$out" "$err"
assert_exit 64 "$ec" "no verb given: exits 64"

test_summary_and_exit
