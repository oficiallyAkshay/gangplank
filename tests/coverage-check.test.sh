#!/usr/bin/env bash
# tests/coverage-check.test.sh — scripts/ci/coverage-check.py against a
# hand-written cobertura fixture (two reports, merged by max hits) and a
# fake diff (--diff-file, no real git needed): both numbers land right,
# and both exit paths (pass, fail on --min-changed) fire correctly.

set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

REPO_ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ci/coverage-check.py"
require_script "$SCRIPT"

command -v python3 >/dev/null 2>&1 || { echo "SKIP - python3 not on PATH"; exit 0; }

dir="$(new_tmpdir)"
mkdir -p "$dir/coverage/kcov-bin1" "$dir/coverage/kcov-bin2"

# Two kcov reports for the same file: merging takes the max hit count
# per line, so line 10 (missed in bin1, hit in bin2) ends up covered.
cat > "$dir/coverage/kcov-bin1/cobertura.xml" <<'EOF'
<?xml version="1.0"?>
<coverage line-rate="0.5"><packages><package name="bin"><classes>
<class name="deploy.sh" filename="/src/bin/deploy.sh"><lines>
<line number="1" hits="1"/><line number="2" hits="0"/><line number="3" hits="1"/>
<line number="10" hits="0"/><line number="11" hits="0"/>
</lines></class></classes></package></packages></coverage>
EOF
cat > "$dir/coverage/kcov-bin2/cobertura.xml" <<'EOF'
<?xml version="1.0"?>
<coverage line-rate="0.5"><packages><package name="bin"><classes>
<class name="deploy.sh" filename="/src/bin/deploy.sh"><lines>
<line number="1" hits="0"/><line number="2" hits="0"/><line number="3" hits="0"/>
<line number="10" hits="1"/><line number="11" hits="0"/>
</lines></class></classes></package></packages></coverage>
EOF
# 5 tracked lines, 3 covered (1, 3, 10) => 60.0% total.

cat > "$dir/diff-fail.txt" <<'EOF'
diff --git a/bin/deploy.sh b/bin/deploy.sh
index abc..def 100644
--- a/bin/deploy.sh
+++ b/bin/deploy.sh
@@ -9,0 +10,2 @@ some context
+echo added1
+echo added2
EOF
cat > "$dir/diff-pass.txt" <<'EOF'
diff --git a/bin/deploy.sh b/bin/deploy.sh
index abc..def 100644
--- a/bin/deploy.sh
+++ b/bin/deploy.sh
@@ -9,0 +10,1 @@ some context
+echo added1
EOF
cat > "$dir/diff-other-file.txt" <<'EOF'
diff --git a/README.md b/README.md
index abc..def 100644
--- a/README.md
+++ b/README.md
@@ -1,0 +2,1 @@
+hello
EOF

run_check() {
  ( cd "$dir" && python3 "$SCRIPT" "$@" )
}

out="$(run_check --diff-file "$dir/diff-fail.txt" --min-changed 90)"
ec=$?
assert_contains "$out" "total=60.0%" "coverage: total line coverage computed across merged reports"
assert_contains "$out" "changed=50.0% (1/2)" "coverage: changed-line coverage counts only the two added lines"
assert_exit 1 "$ec" "coverage: exits 1 when changed coverage is below --min-changed"
assert_contains "$(cat "$dir/coverage/summary.json")" '"changed": 50.0' "coverage: summary.json records the changed percentage"

out="$(run_check --diff-file "$dir/diff-pass.txt" --min-changed 90)"
ec=$?
assert_contains "$out" "changed=100.0% (1/1)" "coverage: a fully-covered added line scores 100%"
assert_exit 0 "$ec" "coverage: exits 0 when changed coverage meets --min-changed"

out="$(run_check --diff-file "$dir/diff-other-file.txt" --min-changed 90)"
ec=$?
assert_contains "$out" "changed=n/a" "coverage: a diff with no bin/ lines reports changed=n/a"
assert_exit 0 "$ec" "coverage: zero changed coverable lines passes regardless of --min-changed"

out="$(run_check)"
ec=$?
assert_contains "$out" "total=60.0%" "coverage: total is still reported with no --base or --diff-file"
assert_contains "$out" "changed=n/a" "coverage: changed-lines bar is skipped with no --base or --diff-file"
assert_exit 0 "$ec" "coverage: no --min-changed given never fails the run"
assert_contains "$(cat "$dir/coverage/summary.json")" '"changed": null' "coverage: summary.json changed is null when skipped"

help_out="$(python3 "$SCRIPT" --help 2>&1)"
assert_contains "$help_out" "usage" "coverage: --help prints usage"

test_summary_and_exit
