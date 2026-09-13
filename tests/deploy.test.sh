#!/usr/bin/env bash
# tests/deploy.test.sh — bin/deploy.sh: the full deploy-script matrix.
#
# Each case builds a fresh bare "origin" repo, a "host" clone (the thing
# under deploy), and a "dev" clone used to push new commits from —
# entirely under a temp dir, torn down at process exit. No associative
# arrays, no `set -u` (see tests/lib.sh — bash 3.2 on macOS).

set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
DEPLOY_SCRIPT="$REPO_ROOT/bin/deploy.sh"
require_script "$DEPLOY_SCRIPT"

DEPLOY_STDOUT=""
DEPLOY_STDERR=""
DEPLOY_EXIT=""
DEPLOY_GH_OUTPUT=""

git_quiet() {
  git "$@" >/dev/null 2>&1
}

# new_fixture — sets ORIGIN, HOST, DEV globals to fresh repo paths with one
# commit on main already present in origin and pulled into host.
new_fixture() {
  local base
  base="$(new_tmpdir)"
  ORIGIN="$base/origin.git"
  HOST="$base/host"
  DEV="$base/dev"

  git init --bare -q "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main

  git clone -q "$ORIGIN" "$DEV"
  (
    cd "$DEV" || exit 1
    git checkout -q -b main 2>/dev/null || git checkout -q main
    git config user.email "dev@example.com"
    git config user.name "dev"
    echo '{"name":"fixture"}' > package.json
    echo "hello" > README.md
    git add package.json README.md
    git commit -q -m "initial commit"
    git push -q origin main
  )

  git clone -q "$ORIGIN" "$HOST"
  (
    cd "$HOST" || exit 1
    git config user.email "host@example.com"
    git config user.name "host"
  )
}

push_commit_from_dev() {
  local msg="$1"
  (
    cd "$DEV" || exit 1
    git pull -q origin main
    echo "$msg" >> README.md
    git add README.md
    git commit -q -m "$msg"
    git push -q origin main
  )
}

run_deploy() {
  # args after HOST override: any GANGPLANK_* env assignments as KEY=VALUE
  local out err ec
  local log lockdir ghoutput
  log="$(mktemp)"
  lockdir="$(new_tmpdir)"
  ghoutput="$(mktemp)"
  out="$(mktemp)"; err="$(mktemp)"

  ( cd "$HOST" && \
    GANGPLANK_REPO="$HOST" \
    GANGPLANK_LOG="$log" \
    GANGPLANK_LOCK_DIR="$lockdir/lock" \
    GITHUB_OUTPUT="$ghoutput" \
    "$@" \
    bash "$DEPLOY_SCRIPT" ) >"$out" 2>"$err"
  ec=$?

  DEPLOY_STDOUT="$(cat "$out")"
  DEPLOY_STDERR="$(cat "$err")"
  DEPLOY_EXIT="$ec"
  DEPLOY_LOG="$(cat "$log" 2>/dev/null || true)"
  DEPLOY_GH_OUTPUT="$(cat "$ghoutput" 2>/dev/null || true)"
  rm -f "$out" "$err"
}

gh_output_value() {
  # gh_output_value KEY — reads KEY=value from DEPLOY_GH_OUTPUT.
  printf '%s\n' "$DEPLOY_GH_OUTPUT" | sed -n "s/^$1=//p" | tail -n1
}

# --- up to date ---
new_fixture
run_deploy env
assert_exit 0 "$DEPLOY_EXIT" "up to date: exits 0"
assert_contains "$DEPLOY_LOG" "up to date" "up to date: log says up to date"
assert_eq "false" "$(gh_output_value deployed)" "up to date: deployed=false"

# --- one new commit pulls ---
new_fixture
push_commit_from_dev "second commit"
run_deploy env
assert_exit 0 "$DEPLOY_EXIT" "one commit: exits 0"
assert_contains "$DEPLOY_LOG" "PULLED 1 commit(s)" "one commit: log says PULLED 1 commit(s)"
assert_eq "true" "$(gh_output_value deployed)" "one commit: deployed=true"
assert_eq "1" "$(gh_output_value commits)" "one commit: commits=1"

# --- dirty tracked file is parked, not re-applied, pull still happens ---
new_fixture
push_commit_from_dev "third commit"
echo "local edit" >> "$HOST/README.md"
run_deploy env
assert_exit 0 "$DEPLOY_EXIT" "dirty tree: exits 0"
assert_contains "$DEPLOY_LOG" "PARKED" "dirty tree: log says PARKED"
stash_list="$(git -C "$HOST" stash list)"
assert_contains "$stash_list" "gangplank park" "dirty tree: stash list has gangplank park entry"
readme_after="$(cat "$HOST/README.md")"
assert_not_contains "$readme_after" "local edit" "dirty tree: local edit not re-applied"
assert_contains "$readme_after" "third commit" "dirty tree: upstream commit still pulled"

# --- diverged host refuses, nothing pulled ---
new_fixture
push_commit_from_dev "origin-side commit"
(
  cd "$HOST" || exit 1
  echo "host only" >> README.md
  git add README.md
  git commit -q -m "host-only local commit"
)
before_head="$(git -C "$HOST" rev-parse HEAD)"
run_deploy env
assert_exit 4 "$DEPLOY_EXIT" "diverged: exits 4"
after_head="$(git -C "$HOST" rev-parse HEAD)"
assert_eq "$before_head" "$after_head" "diverged: HEAD unchanged, nothing pulled"

# --- stranded branch (merged+deleted upstream) is healed back to main ---
new_fixture
(
  cd "$DEV" || exit 1
  git checkout -q -b feature
  echo "feature work" >> README.md
  git add README.md
  git commit -q -m "feature commit"
  git push -q origin feature
)
(
  cd "$HOST" || exit 1
  git fetch -q origin feature
  git checkout -q feature
)
(
  cd "$DEV" || exit 1
  git checkout -q main
  git merge -q --squash feature
  git commit -q -m "squash-merge feature"
  git push -q origin main
  git push -q origin --delete feature
)
run_deploy env
current_branch="$(git -C "$HOST" symbolic-ref --short HEAD)"
assert_eq "main" "$current_branch" "stranded branch: host switched back to main"
assert_exit 0 "$DEPLOY_EXIT" "stranded branch: exits 0"

# --- hook failure: exit 2, pull still happened, later hooks/prune still ran ---
new_fixture
(
  cd "$DEV" || exit 1
  echo '{"name":"fixture","v":2}' > package.json
  git add package.json
  git commit -q -m "bump package.json"
  git push -q origin main
)
run_deploy env GANGPLANK_INSTALL="package.json=false"
assert_exit 2 "$DEPLOY_EXIT" "hook failure: exits 2"
head_after_hookfail="$(git -C "$HOST" rev-parse HEAD)"
origin_head="$(git -C "$ORIGIN" rev-parse refs/heads/main)"
assert_eq "$origin_head" "$head_after_hookfail" "hook failure: pull happened despite hook failure"
pull_line="$(printf '%s\n' "$DEPLOY_LOG" | grep -n 'PULLED' | head -n1 | cut -d: -f1)"
hook_line="$(printf '%s\n' "$DEPLOY_LOG" | grep -n -i 'hook' | head -n1 | cut -d: -f1)"
if [ -n "$pull_line" ] && [ -n "$hook_line" ]; then
  assert_true "$([ "$pull_line" -lt "$hook_line" ] && echo 0 || echo 1)" "hook failure: log shows pull before the hook line"
else
  fail "hook failure: log order check (missing PULLED or hook line — got: $DEPLOY_LOG)"
fi

# --- lock held by a live owner ---
# deploy.sh has no wait-time override: the 600s cap and 5s poll interval
# are hardcoded. Rather than actually wait 600s, stub `sleep` to a no-op
# so the script's own wait loop runs at full speed while a REAL live
# process (started via the absolute path, before the stub goes on PATH)
# keeps holding the lock the whole time.
new_fixture
lockbase="$(new_tmpdir)"
lockdir="$lockbase/lock"
mkdir -p "$lockdir"
/bin/sleep 300 &
live_owner_pid=$!
echo "$live_owner_pid" > "$lockdir/pid"
stub_bin sleep 'exit 0'
out="$(mktemp)"; err="$(mktemp)"; log="$(mktemp)"; ghoutput="$(mktemp)"
( cd "$HOST" && \
  GANGPLANK_REPO="$HOST" \
  GANGPLANK_LOG="$log" \
  GANGPLANK_LOCK_DIR="$lockdir" \
  GITHUB_OUTPUT="$ghoutput" \
  bash "$DEPLOY_SCRIPT" ) >"$out" 2>"$err"
DEPLOY_EXIT=$?
DEPLOY_LOG="$(cat "$log" 2>/dev/null || true)"
assert_exit 3 "$DEPLOY_EXIT" "live lock: exits 3 (deploy.sh has no wait override; sleep is stubbed to reach the hardcoded 600s cap fast)"
assert_contains "$DEPLOY_LOG" "10 minutes" "live lock: log names the reason"
kill "$live_owner_pid" >/dev/null 2>&1 || true
rm -f "$out" "$err" "$log" "$ghoutput"

# --- stale lock from a dead pid is removed, deploy proceeds ---
new_fixture
push_commit_from_dev "stale-lock commit"
lockbase2="$(new_tmpdir)"
lockdir2="$lockbase2/lock"
mkdir -p "$lockdir2"
( sleep 0.1 & echo $! > "$lockdir2/pid" )
sleep 1
run_deploy env GANGPLANK_LOCK_DIR="$lockdir2"
assert_contains "$DEPLOY_LOG" "stale lock" "stale lock: log mentions stale lock removal"
assert_exit 0 "$DEPLOY_EXIT" "stale lock: deploy still proceeds"

# --- GANGPLANK_REPO unset -> bad config ---
new_fixture
out="$(mktemp)"; err="$(mktemp)"
( cd "$HOST" && env -u GANGPLANK_REPO bash "$DEPLOY_SCRIPT" ) >"$out" 2>"$err"
DEPLOY_EXIT=$?
assert_exit 64 "$DEPLOY_EXIT" "GANGPLANK_REPO unset: exits 64"
rm -f "$out" "$err"

# --- fetch failure ---
new_fixture
mv "$ORIGIN" "${ORIGIN}.gone"
run_deploy env
assert_exit 5 "$DEPLOY_EXIT" "fetch failure: exits 5"
mv "${ORIGIN}.gone" "$ORIGIN" 2>/dev/null || true

# --- GANGPLANK_PRUNE_WORKTREES=false skips the prune ---
# The skip note is logged at debug level (deploy.sh's debug() helper only
# writes when GANGPLANK_DEBUG=1) — set it so the note is observable.
new_fixture
push_commit_from_dev "prune-skip commit"
run_deploy env GANGPLANK_PRUNE_WORKTREES=false GANGPLANK_DEBUG=1
assert_exit 0 "$DEPLOY_EXIT" "prune skipped: exits 0"
assert_contains "$DEPLOY_LOG" "skipping prune" "prune skipped: log names the prune step"

# --- GANGPLANK_SERVICES_DIR plist named <self-label>.plist is a hand step ---
# GANGPLANK_SERVICES_DIR is documented as repo-relative (deploy.sh's own
# header comment) — an absolute path never matches the relative paths
# `git diff --name-only` reports, so the hook silently no-ops.
new_fixture
stub_bin launchctl 'echo "launchctl $*" >> "$LAUNCHCTL_CALLS_LOG"; exit 0'
calls_log="$(new_tmpdir)/launchctl-calls.log"
: > "$calls_log"
(
  cd "$DEV" || exit 1
  mkdir -p services
  echo '<plist self-label v1/>' > services/ai.gangplank.self.plist
  git add services/ai.gangplank.self.plist
  git commit -q -m "add self plist"
  git push -q origin main
)
(
  cd "$HOST" || exit 1
  git pull -q origin main
)
(
  cd "$DEV" || exit 1
  echo '<plist self-label v2/>' > services/ai.gangplank.self.plist
  git add services/ai.gangplank.self.plist
  git commit -q -m "change self plist"
  git push -q origin main
)
LAUNCHCTL_CALLS_LOG="$calls_log" run_deploy env GANGPLANK_SERVICES_DIR="services" GANGPLANK_SELF_LABEL="ai.gangplank.self"
assert_exit 0 "$DEPLOY_EXIT" "self-plist change: exits 0"
assert_contains "$DEPLOY_LOG" "reload it by hand" "self-plist change: log calls it a hand step"
calls_content="$(cat "$calls_log" 2>/dev/null || true)"
assert_not_contains "$calls_content" "ai.gangplank.self" "self-plist change: launchctl never called with the self label"

test_summary_and_exit
