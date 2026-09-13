#!/usr/bin/env python3
# scripts/ci/coverage-check.py — reads kcov's cobertura reports under
# coverage/**/cobertura.xml (kcov writes one per traced binary; merged
# here by taking the max hit count per file+line), computes total line
# coverage for bin/ and, when a base ref or diff is given, coverage of
# just the added lines under bin/. No Codecov, no upload, no token.
#
# Exits 1 only when --min-changed is given, at least one changed line is
# coverable, and its coverage is below the threshold.
import argparse
import glob
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


def canon_bin_path(path):
    path = path.replace("\\", "/")
    idx = path.rfind("/bin/")
    if idx != -1:
        return path[idx + 1:]
    return path if path.startswith("bin/") else None


def load_coverage(pattern="coverage/**/cobertura.xml"):
    data = {}
    for report in glob.glob(pattern, recursive=True):
        try:
            root = ET.parse(report).getroot()
        except ET.ParseError:
            continue
        for cls in root.iter("class"):
            canon = canon_bin_path(cls.get("filename", ""))
            if canon is None:
                continue
            lines = data.setdefault(canon, {})
            for line in cls.iter("line"):
                num, hits = int(line.get("number")), int(line.get("hits", "0"))
                lines[num] = max(lines.get(num, 0), hits)
    return data


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


def totals(cov, lines_by_file=None):
    covered = total = 0
    for canon, lines in cov.items():
        wanted = lines.keys() if lines_by_file is None else lines_by_file.get(canon, ())
        for num in wanted:
            if num in lines:
                total += 1
                covered += 1 if lines[num] > 0 else 0
    return covered, total


def main():
    p = argparse.ArgumentParser(description="Line and changed-line coverage over bin/, from kcov's cobertura output.")
    p.add_argument("--base", help="ref to diff against for changed-line coverage; omit to skip that bar")
    p.add_argument("--diff-file", help="unified diff to use instead of running git (for tests)")
    p.add_argument("--min-changed", type=float, help="fail if changed-line coverage drops below this percent")
    args = p.parse_args()

    cov = load_coverage()
    total_covered, total_total = totals(cov)
    total_pct = round(100.0 * total_covered / total_total, 1) if total_total else 0.0

    diff_text = None
    if args.diff_file:
        diff_text = open(args.diff_file).read()
    elif args.base:
        diff_text = subprocess.run(
            ["git", "diff", "--unified=0", f"{args.base}...HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout

    changed_pct, changed_covered, changed_total = None, 0, 0
    if diff_text is not None:
        changed_covered, changed_total = totals(cov, parse_added_lines(diff_text))
        if changed_total:
            changed_pct = round(100.0 * changed_covered / changed_total, 1)

    with open("coverage/summary.json", "w") as f:
        json.dump({"total": total_pct, "changed": changed_pct, "changed_lines": changed_total}, f)

    changed_part = f"changed={changed_pct}% ({changed_covered}/{changed_total})" if changed_pct is not None else "changed=n/a"
    print(f"total={total_pct}% {changed_part}")

    return 1 if (args.min_changed is not None and changed_total > 0 and changed_pct < args.min_changed) else 0


if __name__ == "__main__":
    sys.exit(main())
