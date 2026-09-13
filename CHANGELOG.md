# Changelog

One line per merged change, newest first. No version numbers here.

- A stale lock with no pid file is aged correctly on Linux too; the old stat call read the mount point there and aborted the deploy.
- Tests for every parking, restore, resume and log-dir path in deploy.sh; the coverage checker's --list-uncovered prints the changed lines a PR still misses.
- The code: gate, deploy step as a composite action, installer, CLI, tests, CI and coverage config.
- The deploy hook plist step creates a plist's StandardOutPath/StandardErrorPath directories before bootstrapping it.
- Hook and prune runs resume from the last completed SHA after a crash, even on a run that pulls nothing new (GANGPLANK_STATE_DIR/last-hooked-sha).
- Deploy only parks a dirty tree once it knows a fast-forward is happening, pops the stash back if that fast-forward then fails, and can run a GANGPLANK_ON_PARK/on_park command once a parked deploy lands.
- Contribution runbook, CI and test plan, PR template.
- README with the system and deploy diagrams.
