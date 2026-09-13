#!/usr/bin/env bash
# tests/installer.test.sh — bin/install-runner.sh: dry-run, missing --repo,
# and the sha256-mismatch refusal on a real download path.
#
# No associative arrays, no `set -u` (see tests/lib.sh — bash 3.2 on
# macOS). This test never lets a real run reach registration or
# launchctl: the sha256 mismatch case exits before either.

set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
INSTALLER="$REPO_ROOT/bin/install-runner.sh"
require_script "$INSTALLER"

stub_gh_ok() {
  stub_bin gh '
case "$1" in
  auth) exit 0 ;;
  api) echo "gh-fake-registration-token" ;;
  *) exit 1 ;;
esac
'
}

# --- dry-run: prints every planned action, creates nothing, redacts token ---
runner_dir="$(new_tmpdir)/runner"
stub_gh_ok
out="$(mktemp)"; err="$(mktemp)"
bash "$INSTALLER" --repo owner/repo --runner-dir "$runner_dir" --dry-run >"$out" 2>"$err"
ec=$?
dry_out="$(cat "$out")"
dry_err="$(cat "$err")"
rm -f "$out" "$err"

assert_exit 0 "$ec" "dry-run: exits 0"
assert_contains "$dry_out" "download" "dry-run: prints the planned download"
assert_contains "$dry_out" "sha256" "dry-run: mentions the sha256 verification step"
assert_contains "$dry_out" "***REDACTED***" "dry-run: registration token is redacted"
assert_not_contains "$dry_out" "gh-fake-registration-token" "dry-run: real token never printed"
assert_contains "$dry_out" "hooks/job-started-gate.sh" "dry-run: prints the hook path"
assert_contains "$dry_out" "verify" "dry-run: prints the verify plan"
if [ -e "$runner_dir" ]; then
  fail "dry-run: creates nothing under --runner-dir (found $runner_dir)"
else
  pass "dry-run: creates nothing under --runner-dir"
fi

# --- --repo missing: non-zero exit, clear line ---
out="$(mktemp)"; err="$(mktemp)"
bash "$INSTALLER" --dry-run >"$out" 2>"$err"
ec=$?
missing_err="$(cat "$err")"
rm -f "$out" "$err"
if [ "$ec" -eq 0 ]; then
  fail "missing --repo: exits non-zero (got 0)"
else
  pass "missing --repo: exits non-zero"
fi
assert_contains "$missing_err" "--repo is required" "missing --repo: clear line naming the missing flag"

# --- real download path: stubbed curl writes a wrong file -> sha256 mismatch ---
# The script downloads (and verifies) before it ever registers with GitHub,
# so this never reaches gh/config.sh/launchctl — confirmed by the absence
# of any need to stub gh here (a call to gh with no stub would itself fail
# loudly, which the assertions below would catch via the wrong error text).
runner_dir2="$(new_tmpdir)/runner2"
stub_bin curl '
# emulate: curl -fsSL -o <path> <url> — write bogus content regardless of URL
out_path=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out_path="$a"; fi
  prev="$a"
done
[ -n "$out_path" ] && printf "not the real runner tarball\n" > "$out_path"
exit 0
'
out="$(mktemp)"; err="$(mktemp)"
GANGPLANK_TEST_RUNNER_VERSION="0.0.0-test" \
GANGPLANK_TEST_RUNNER_SHA256="0000000000000000000000000000000000000000000000000000000000aa" \
bash "$INSTALLER" --repo owner/repo --runner-dir "$runner_dir2" >"$out" 2>"$err"
ec=$?
mismatch_out="$(cat "$out")"
mismatch_err="$(cat "$err")"
rm -f "$out" "$err"

if [ "$ec" -eq 0 ]; then
  fail "sha256 mismatch: exits non-zero (got 0)"
else
  pass "sha256 mismatch: exits non-zero"
fi
combined="$mismatch_out
$mismatch_err"
assert_contains "$combined" "sha256 mismatch" "sha256 mismatch: refusal line names it"
assert_not_contains "$combined" "config.sh" "sha256 mismatch: never reaches registration (config.sh)"

test_summary_and_exit
