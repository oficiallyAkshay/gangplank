#!/bin/bash
# on_failure / on_recovery command for gangplank's action.yml. Sends one
# email via the box's own `mail` (or `mailx`) command. Needs MAIL_TO set;
# mail delivery itself is whatever this Mac already has configured
# (sendmail, postfix, an SMTP relay) — gangplank does not set that up.
set -uo pipefail
if [ -z "${MAIL_TO:-}" ]; then
  echo "on-failure-mail: MAIL_TO not set, skipping" >&2
  exit 0
fi
if [ "${GANGPLANK_EXIT_CODE:-1}" = "0" ]; then
  subject="Deploy recovered"
  body="${GANGPLANK_RUN_URL:-unknown run}"
else
  subject="Deploy failed (exit ${GANGPLANK_EXIT_CODE:-?})"
  body="${GANGPLANK_REASON:-see the run log}
${GANGPLANK_RUN_URL:-unknown run}"
fi
printf '%s\n' "${body}" | mail -s "${subject}" "${MAIL_TO}"
