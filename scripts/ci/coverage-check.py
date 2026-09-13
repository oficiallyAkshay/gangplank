#!/usr/bin/env python3
# scripts/ci/coverage-check.py — reads the trace file produced by
# scripts/ci/trace.sh (sourced via BASH_ENV by every bash process the
# test run starts, appending "+trace:<path>:<lineno>:" xtrace lines —
# the "+" repeats with call-nesting depth), computes total line coverage
# for bin/ and, when a base ref or diff is given, coverage of just the
# added lines under bin/. No kcov, no container, no Codecov, no upload.
#
# A line is "coverable" when it is not blank, not a comment, and not a
# bare structural token on its own (`{`, `}`, `fi`, `done`, `esac`,
# `else`, `then`, `do`, `;;`, `)`) — bash never traces those on their
# own line, so counting them as coverable would put a ceiling below
# 100% on files that are fully exercised.
#
# Exits 1 only when --min-changed is given, at least one changed line is
# coverable, and its coverage is below the threshold.
import argparse
import glob
import json
import os
import re
import subprocess
import sys

TRACE_RE = re.compile(r"^\++trace:(.+):(\d+):")
STRUCTURAL_TOKENS = {"{", "}", "fi", "done", "esac", "else", "then", "do", ";;", ")"}


def canon_bin_path(path, repo_root):
    path = path.replace("\\", "/")
    if not os.path.isabs(path):
        path = os.path.normpath(os.path.join(repo_root, path))
    idx = path.rfind("/bin/")
    return path[idx + 1:] if idx != -1 else None


def is_coverable(line):
    text = line.strip()
    return bool(text) and not text.startswith("#") and text not in STRUCTURAL_TOKENS


def load_coverable(repo_root):
    coverable = {}
    for path in sorted(glob.glob(os.path.join(repo_root, "bin", "*"))):
        if not os.path.isfile(path):
            continue
        with open(path, errors="replace") as f:
            lines = {n for n, line in enumerate(f, start=1) if is_coverable(line)}
        coverable["bin/" + os.path.basename(path)] = lines
    return coverable


def load_trace(trace_path, repo_root):
    executed = {}
    try:
        f = open(trace_path)
    except OSError:
        return executed
    with f:
        for line in f:
            m = TRACE_RE.match(line)
            if not m:
                continue
            canon = canon_bin_path(m.group(1), repo_root)
            if canon is None:
                continue
            executed.setdefault(canon, set()).add(int(m.group(2)))
    return executed


def parse_added_lines(diff_text):
    # Unified diff, --unified=0: a '+' line is added/modified in the new
    # file at the running new_line counter; '-' lines don't advance it.
    added, current_file, new_line = {}, None, None
    for line in diff_text.splitlines():
        if line.startswith("--- "):
            continue
        if line.startswith("+++ "):
            path = line[4:].strip()
            current_file = None if path == "/dev/null" else re.sub(r"^[ab]/", "", path)
        elif line.startswith("@@"):
            m = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", line)
            new_line = int(m.group(1)) if m else new_line
        elif current_file is not None and new_line is not None:
            if line.startswith("+"):
                added.setdefault(current_file, set()).add(new_line)
                new_line += 1
            elif line.startswith(" "):
                new_line += 1
    return added


def totals(coverable, executed, lines_by_file=None):
    covered = total = 0
    for canon, cov_lines in coverable.items():
        wanted = cov_lines if lines_by_file is None else (lines_by_file.get(canon, set()) & cov_lines)
        total += len(wanted)
        covered += len(wanted & executed.get(canon, set()))
    return covered, total


def main():
    p = argparse.ArgumentParser(description="Line and changed-line coverage over bin/, from bash's own xtrace output.")
    p.add_argument("--trace", default="coverage/trace.log", help="trace file written by scripts/ci/trace.sh")
    p.add_argument("--repo-root", default=".", help="repo root bin/ is measured under")
    p.add_argument("--base", help="ref to diff against for changed-line coverage; omit to skip that bar")
    p.add_argument("--diff-file", help="unified diff to use instead of running git (for tests)")
    p.add_argument("--min-changed", type=float, help="fail if changed-line coverage drops below this percent")
    args = p.parse_args()

    repo_root = os.path.abspath(args.repo_root)
    coverable = load_coverable(repo_root)
    executed = load_trace(args.trace, repo_root)

    total_covered, total_total = totals(coverable, executed)
    total_pct = round(100.0 * total_covered / total_total, 1) if total_total else 0.0

    diff_text = None
    if args.diff_file:
        diff_text = open(args.diff_file).read()
    elif args.base:
        diff_text = subprocess.run(
            ["git", "diff", "--unified=0", f"{args.base}...HEAD"],
            capture_output=True, text=True, check=True, cwd=repo_root,
        ).stdout

    changed_pct, changed_covered, changed_total = None, 0, 0
    if diff_text is not None:
        changed_covered, changed_total = totals(coverable, executed, parse_added_lines(diff_text))
        if changed_total:
            changed_pct = round(100.0 * changed_covered / changed_total, 1)

    with open(os.path.join(repo_root, "coverage", "summary.json"), "w") as f:
        json.dump({"total": total_pct, "changed": changed_pct, "changed_lines": changed_total}, f)

    changed_part = f"changed={changed_pct}% ({changed_covered}/{changed_total})" if changed_pct is not None else "changed=n/a"
    print(f"total={total_pct}% {changed_part}")

    return 1 if (args.min_changed is not None and changed_total > 0 and changed_pct < args.min_changed) else 0


if __name__ == "__main__":
    sys.exit(main())
