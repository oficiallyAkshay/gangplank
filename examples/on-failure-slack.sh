#!/bin/bash
# on_failure / on_recovery command for gangplank's action.yml. Posts one
# Slack message via an incoming webhook. Needs SLACK_WEBHOOK_URL in the
# runner's environment (or the workflow's `env:`) — never hardcode it here.
set -uo pipefail
if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
  echo "on-failure-slack: SLACK_WEBHOOK_URL not set, skipping" >&2
  exit 0
fi
if [ "${GANGPLANK_EXIT_CODE:-1}" = "0" ]; then
  text="Deploy recovered — ${GANGPLANK_RUN_URL:-unknown run}"
else
  text="Deploy failed (exit ${GANGPLANK_EXIT_CODE:-?}): ${GANGPLANK_REASON:-see the run log} — ${GANGPLANK_RUN_URL:-unknown run}"
fi
curl -fsS -X POST -H 'Content-Type: application/json' \
  -d "$(printf '{"text":"%s"}' "${text//\"/\\\"}")" \
  "${SLACK_WEBHOOK_URL}" >/dev/null
