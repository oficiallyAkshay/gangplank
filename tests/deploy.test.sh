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

# --- services hook: a new plist is copied and bootstrapped ---
new_fixture
stub_bin launchctl 'echo "launchctl $*" >> "$LAUNCHCTL_CALLS_LOG"; exit 0'
new_plist_home="$(new_tmpdir)"
new_plist_calls="$(new_tmpdir)/launchctl-calls.log"
: > "$new_plist_calls"
(
  cd "$DEV" || exit 1
  mkdir -p services
  echo '<plist new-daemon v1/>' > services/ai.gangplank.newdaemon.plist
  git add services/ai.gangplank.newdaemon.plist
  git commit -q -m "add new daemon plist"
  git push -q origin main
)
LAUNCHCTL_CALLS_LOG="$new_plist_calls" run_deploy env HOME="$new_plist_home" GANGPLANK_SERVICES_DIR="services"
assert_exit 0 "$DEPLOY_EXIT" "new plist: exits 0"
installed_new_plist="$new_plist_home/Library/LaunchAgents/ai.gangplank.newdaemon.plist"
if [ -f "$installed_new_plist" ]; then
  pass "new plist: copy lands in the fake HOME/Library/LaunchAgents"
else
  fail "new plist: copy lands in the fake HOME/Library/LaunchAgents (missing $installed_new_plist)"
fi
new_plist_calls_content="$(cat "$new_plist_calls")"
assert_contains "$new_plist_calls_content" "bootstrap" "new plist: launchctl bootstrap recorded"

# --- services hook: a plist renamed to .plist.disabled is unloaded ---
new_fixture
(
  cd "$DEV" || exit 1
  mkdir -p services
  echo '<plist to-disable v1/>' > services/ai.gangplank.tobedisabled.plist
  git add services/ai.gangplank.tobedisabled.plist
  git commit -q -m "add tobedisabled plist"
  git push -q origin main
)
( cd "$HOST" || exit 1; git pull -q origin main )
stub_bin launchctl 'echo "launchctl $*" >> "$LAUNCHCTL_CALLS_LOG"; exit 0'
disable_calls="$(new_tmpdir)/launchctl-calls.log"
: > "$disable_calls"
(
  cd "$DEV" || exit 1
  git mv services/ai.gangplank.tobedisabled.plist services/ai.gangplank.tobedisabled.plist.disabled
  git commit -q -m "disable daemon"
  git push -q origin main
)
LAUNCHCTL_CALLS_LOG="$disable_calls" run_deploy env HOME="$(new_tmpdir)" GANGPLANK_SERVICES_DIR="services"
assert_exit 0 "$DEPLOY_EXIT" "disabled plist: exits 0"
assert_contains "$DEPLOY_LOG" "renamed to .disabled" "disabled plist: log calls out the rename"
disable_calls_content="$(cat "$disable_calls")"
assert_contains "$disable_calls_content" "bootout" "disabled plist: launchctl bootout recorded"
assert_contains "$disable_calls_content" "ai.gangplank.tobedisabled" "disabled plist: bootout named the right label"

# --- services hook: a deleted plist is unloaded and its copy removed ---
new_fixture
(
  cd "$DEV" || exit 1
  mkdir -p services
  echo '<plist to-delete v1/>' > services/ai.gangplank.todelete.plist
  git add services/ai.gangplank.todelete.plist
  git commit -q -m "add todelete plist"
  git push -q origin main
)
( cd "$HOST" || exit 1; git pull -q origin main )
delete_home="$(new_tmpdir)"
mkdir -p "$delete_home/Library/LaunchAgents"
echo '<plist stale copy/>' > "$delete_home/Library/LaunchAgents/ai.gangplank.todelete.plist"
stub_bin launchctl 'echo "launchctl $*" >> "$LAUNCHCTL_CALLS_LOG"; exit 0'
delete_calls="$(new_tmpdir)/launchctl-calls.log"
: > "$delete_calls"
(
  cd "$DEV" || exit 1
  git rm -q services/ai.gangplank.todelete.plist
  git commit -q -m "remove todelete plist"
  git push -q origin main
)
LAUNCHCTL_CALLS_LOG="$delete_calls" run_deploy env HOME="$delete_home" GANGPLANK_SERVICES_DIR="services"
assert_exit 0 "$DEPLOY_EXIT" "deleted plist: exits 0"
assert_contains "$DEPLOY_LOG" "gone (removed or renamed to .disabled) — unloading" "deleted plist: log calls out the removal"
delete_calls_content="$(cat "$delete_calls")"
assert_contains "$delete_calls_content" "bootout" "deleted plist: launchctl bootout recorded"
if [ -f "$delete_home/Library/LaunchAgents/ai.gangplank.todelete.plist" ]; then
  fail "deleted plist: stale copy removed from LaunchAgents (still present)"
else
  pass "deleted plist: stale copy removed from LaunchAgents"
fi

# --- GANGPLANK_KICK: kickstart called for every named label ---
new_fixture
push_commit_from_dev "kick commit"
stub_bin launchctl 'echo "launchctl $*" >> "$LAUNCHCTL_CALLS_LOG"; exit 0'
kick_calls="$(new_tmpdir)/launchctl-calls.log"
: > "$kick_calls"
LAUNCHCTL_CALLS_LOG="$kick_calls" run_deploy env GANGPLANK_KICK="daemon.one daemon.two"
assert_exit 0 "$DEPLOY_EXIT" "kick: exits 0"
kick_calls_content="$(cat "$kick_calls")"
assert_contains "$kick_calls_content" "kickstart -k gui/" "kick: launchctl kickstart -k invoked"
assert_contains "$kick_calls_content" "daemon.one" "kick: daemon.one kicked"
assert_contains "$kick_calls_content" "daemon.two" "kick: daemon.two kicked"

# --- GANGPLANK_INSTALL=none skips every install hook ---
new_fixture
(
  cd "$DEV" || exit 1
  echo '{"name":"fixture","v":2}' > package.json
  git add package.json
  git commit -q -m "bump package.json"
  git push -q origin main
)
run_deploy env GANGPLANK_INSTALL=none GANGPLANK_DEBUG=1
assert_exit 0 "$DEPLOY_EXIT" "install=none: exits 0"
assert_contains "$DEPLOY_LOG" "GANGPLANK_INSTALL=none, skipping install hooks" "install=none: log names the skip"
assert_not_contains "$DEPLOY_LOG" "hook: install in" "install=none: no install hook ran"

# --- custom glob=command pair runs in the changed file's directory ---
new_fixture
(
  cd "$DEV" || exit 1
  mkdir -p sub
  echo "x" > sub/marker.txt
  git add sub/marker.txt
  git commit -q -m "add marker"
  git push -q origin main
)
run_deploy env GANGPLANK_INSTALL="marker.txt=touch ran-custom-hook.txt"
assert_exit 0 "$DEPLOY_EXIT" "custom glob: exits 0"
if [ -f "$HOST/sub/ran-custom-hook.txt" ]; then
  pass "custom glob: command ran in the changed file's directory"
else
  fail "custom glob: command ran in the changed file's directory (marker not found)"
fi

# --- GANGPLANK_DEBUG=1 prints debug lines; unset prints none ---
new_fixture
run_deploy env GANGPLANK_DEBUG=1
assert_exit 0 "$DEPLOY_EXIT" "debug on: exits 0"
assert_contains "$DEPLOY_LOG" "debug: behind=0 ahead=0" "debug on: debug lines present"

new_fixture
run_deploy env
assert_exit 0 "$DEPLOY_EXIT" "debug off: exits 0"
assert_not_contains "$DEPLOY_LOG" "debug:" "debug off: no debug lines"

# --- GANGPLANK_DRY_RUN=1: deploy.sh has no dry-run support, so it is
# inert — the flag changes nothing and a real deploy still happens.
new_fixture
push_commit_from_dev "dry-run-flag commit"
run_deploy env GANGPLANK_DRY_RUN=1
assert_exit 0 "$DEPLOY_EXIT" "GANGPLANK_DRY_RUN=1: exits 0 same as without it"
assert_contains "$DEPLOY_LOG" "PULLED 1 commit(s)" "GANGPLANK_DRY_RUN=1: still pulls for real (flag is a no-op in deploy.sh)"
assert_eq "true" "$(gh_output_value deployed)" "GANGPLANK_DRY_RUN=1: deployed=true (not a dry run)"

# --- worktree prune: gh reports MERGED for one branch, OPEN for another ---
new_fixture
push_commit_from_dev "worktree-prune commit"
wt_merged="$(new_tmpdir)/wt-merged"
wt_open="$(new_tmpdir)/wt-open"
git -C "$HOST" worktree add -q -b feature-merged "$wt_merged" >/dev/null 2>&1
git -C "$HOST" worktree add -q -b feature-open "$wt_open" >/dev/null 2>&1
stub_bin gh '
case "$1" in
  pr)
    head=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--head" ]; then head="$a"; fi
      prev="$a"
    done
    case "$head" in
      feature-merged) echo "42" ;;
      *) echo "" ;;
    esac
    exit 0
    ;;
  *) exit 1 ;;
esac
'
run_deploy env
assert_exit 0 "$DEPLOY_EXIT" "worktree prune: exits 0"
assert_contains "$DEPLOY_LOG" "worktree PRUNED" "worktree prune: log names a pruned worktree"
assert_contains "$DEPLOY_LOG" "(feature-merged, merged PR #42)" "worktree prune: merged branch pruned with its PR number"
assert_contains "$DEPLOY_LOG" "clean but no merged PR found, keeping" "worktree prune: open branch kept"
if [ -d "$wt_merged" ]; then
  fail "worktree prune: merged worktree removed (still present)"
else
  pass "worktree prune: merged worktree removed"
fi
if [ -d "$wt_open" ]; then
  pass "worktree prune: open worktree left in place"
else
  fail "worktree prune: open worktree left in place (was removed)"
fi
if git -C "$HOST" rev-parse --verify --quiet refs/heads/feature-merged >/dev/null 2>&1; then
  fail "worktree prune: merged local branch deleted (still exists)"
else
  pass "worktree prune: merged local branch deleted"
fi
if git -C "$HOST" rev-parse --verify --quiet refs/heads/feature-open >/dev/null 2>&1; then
  pass "worktree prune: open local branch kept"
else
  fail "worktree prune: open local branch kept (was deleted)"
fi

# --- GANGPLANK_BRANCH tracks a non-main branch end to end ---
base_nb="$(new_tmpdir)"
ORIGIN="$base_nb/origin.git"
HOST="$base_nb/host"
DEV="$base_nb/dev"
git init --bare -q "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git clone -q "$ORIGIN" "$DEV"
(
  cd "$DEV" || exit 1
  git checkout -q -b main 2>/dev/null || git checkout -q main
  git config user.email "dev@example.com"
  git config user.name "dev"
  echo "hello" > README.md
  git add README.md
  git commit -q -m "initial commit on main"
  git push -q origin main
  git checkout -q -b release
  git push -q origin release
)
git clone -q "$ORIGIN" "$HOST"
(
  cd "$HOST" || exit 1
  git config user.email "host@example.com"
  git config user.name "host"
  git fetch -q origin release
  git checkout -q release
)
(
  cd "$DEV" || exit 1
  git checkout -q release
  echo "release work" >> README.md
  git add README.md
  git commit -q -m "release commit"
  git push -q origin release
)
run_deploy env GANGPLANK_BRANCH=release
assert_exit 0 "$DEPLOY_EXIT" "non-main branch: exits 0"
assert_contains "$DEPLOY_LOG" "PULLED 1 commit(s)" "non-main branch: pulled the release-branch commit"
release_branch_after="$(git -C "$HOST" symbolic-ref --short HEAD)"
assert_eq "release" "$release_branch_after" "non-main branch: host stayed on release"
readme_on_release="$(cat "$HOST/README.md")"
assert_contains "$readme_on_release" "release work" "non-main branch: release commit content landed"


# --- GANGPLANK_REPO points at something that is not a git checkout ---
not_a_repo="$(new_tmpdir)/plainfolder"
mkdir -p "$not_a_repo"
out="$(mktemp)"; err="$(mktemp)"
( GANGPLANK_REPO="$not_a_repo" bash "$DEPLOY_SCRIPT" ) >"$out" 2>"$err"
notrepo_ec=$?
notrepo_err="$(cat "$err")"
rm -f "$out" "$err"
assert_exit 64 "$notrepo_ec" "not a git checkout: exits 64"
assert_contains "$notrepo_err" "is not a git checkout" "not a git checkout: clear line naming the problem"

# --- AHEAD only: local unpushed commits, nothing pulled ---
new_fixture
(
  cd "$HOST" || exit 1
  echo "local only commit" >> README.md
  git add README.md
  git commit -q -m "local-only commit"
)
before_ahead_head="$(git -C "$HOST" rev-parse HEAD)"
run_deploy env
assert_exit 0 "$DEPLOY_EXIT" "ahead only: exits 0"
assert_contains "$DEPLOY_LOG" "AHEAD 1 (local has un-pushed commits" "ahead only: log names the ahead-only state"
after_ahead_head="$(git -C "$HOST" rev-parse HEAD)"
assert_eq "$before_ahead_head" "$after_ahead_head" "ahead only: HEAD unchanged"
assert_eq "false" "$(gh_output_value deployed)" "ahead only: deployed=false"

# --- worktree prune: gh missing from PATH skips the whole step ---
# GitHub's own ubuntu-latest runners ship gh on the default PATH, so a
# hardcoded low-level dir list (e.g. /usr/bin:/bin) is not a reliable way
# to make gh absent there — it only worked on this Mac because gh isn't
# under those two dirs locally. Build the "no gh" condition explicitly
# instead: a PATH containing symlinks for only the binaries bin/deploy.sh
# itself calls (bash, to exec the script under the restricted PATH, plus
# every external command the script shells out to), skipping any that
# aren't present on this host, and never gh.
no_gh_bindir="$(new_tmpdir)/no-gh-bin"
mkdir -p "$no_gh_bindir"
for tool in bash git date mkdir rm cat grep sed sort tr basename dirname id sleep kill printf cp stat; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$tool_path" ] && ln -s "$tool_path" "$no_gh_bindir/$tool"
done
no_gh_path="$no_gh_bindir"
new_fixture
push_commit_from_dev "prune-no-gh commit"
run_deploy env PATH="$no_gh_path"
assert_exit 0 "$DEPLOY_EXIT" "prune without gh: exits 0"
assert_contains "$DEPLOY_LOG" "worktree prune SKIPPED — gh not on PATH" "prune without gh: log names the skip"

# --- worktree prune: a locked worktree is skipped, a dirty one is skipped ---
new_fixture
push_commit_from_dev "prune-locked-dirty commit"
wt_locked="$(new_tmpdir)/wt-locked"
wt_dirty="$(new_tmpdir)/wt-dirty"
git -C "$HOST" worktree add -q -b feature-locked "$wt_locked" >/dev/null 2>&1
git -C "$HOST" worktree add -q -b feature-dirty "$wt_dirty" >/dev/null 2>&1
git -C "$HOST" worktree lock "$wt_locked" >/dev/null 2>&1
echo "uncommitted edit" >> "$wt_dirty/README.md"
stub_bin gh 'echo ""; exit 0'
run_deploy env
assert_exit 0 "$DEPLOY_EXIT" "prune locked+dirty: exits 0"
assert_contains "$DEPLOY_LOG" "(feature-locked) — locked by an active session" "prune locked+dirty: locked worktree named and skipped"
assert_contains "$DEPLOY_LOG" "(feature-dirty) — dirty or missing" "prune locked+dirty: dirty worktree named and skipped"
if [ -d "$wt_locked" ]; then
  pass "prune locked+dirty: locked worktree left in place"
else
  fail "prune locked+dirty: locked worktree left in place (was removed)"
fi
if [ -d "$wt_dirty" ]; then
  pass "prune locked+dirty: dirty worktree left in place"
else
  fail "prune locked+dirty: dirty worktree left in place (was removed)"
fi


test_summary_and_exit
