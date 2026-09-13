# Makefile — the same checks CI runs, runnable locally.
#
# check   shellcheck + actionlint (if present) + tests
# test    tests/run.sh alone
# lint    shellcheck + actionlint (if present), no tests
# coverage  tests/run.sh under kcov (if present), else prints how to get it

SHELL := /bin/bash

SH_SCRIPTS := $(wildcard bin/*) $(wildcard examples/*.sh) $(wildcard tests/*.sh)
WORKFLOW_FILES := $(wildcard .github/workflows/*.yml)

.PHONY: check test lint coverage

check: lint test

test:
	bash tests/run.sh

lint:
	@echo "==> shellcheck --severity=error"
	shellcheck --severity=error $(SH_SCRIPTS)
	@if command -v actionlint >/dev/null 2>&1; then \
		echo "==> actionlint"; \
		actionlint $(WORKFLOW_FILES); \
	else \
		echo "==> actionlint not on PATH — skipping (CI installs it; see CONTRIBUTING.md)"; \
	fi
	# action.yml is a composite-action definition, not a workflow file:
	# actionlint has no standalone schema for it and misparses it as a
	# malformed workflow if handed the path directly (tried; every
	# top-level key past 'name' errors as "missing jobs/on section").
	# It only validates a composite action in context, when a real
	# workflow's step does `uses: ./` — tests/action.test.sh covers
	# action.yml's shape instead (composite, required inputs, no
	# third-party uses:, no checkout).

coverage:
	@if command -v kcov >/dev/null 2>&1; then \
		mkdir -p coverage; \
		kcov --include-path=bin coverage tests/run.sh; \
	else \
		echo "kcov not found. Install it to measure coverage locally:"; \
		echo "  macOS:  brew install kcov"; \
		echo "  Linux:  see https://github.com/SimonKagstrom/kcov#installing"; \
		echo "CI always runs coverage regardless of what's installed here."; \
	fi
