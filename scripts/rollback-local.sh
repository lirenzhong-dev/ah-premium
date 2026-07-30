#!/usr/bin/env bash
# RENDERED from ~/AgentOS/deployment/templates/project-scripts/rollback-local.sh.template
# by onboard-project.sh. Do not edit — re-render from the template.

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_NAME="ah-premium"
APP_DIR="/opt/projects/ah-premium"
SSH_HOST="tencent-production"
SSH_BIN="/usr/bin/ssh"
SERVER_BIN="${APP_DIR}/bin/rollback"

ASSUME_YES="false"
DRY_RUN="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)  ASSUME_YES="true"; shift ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --ssh-host) SSH_HOST="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

echo "==> ${PROJECT_NAME} rollback"
echo "    target: ${SSH_HOST}"
"${SSH_BIN}" "${SSH_HOST}" "agentos status ${PROJECT_NAME}" || true
echo

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "(dry-run) would invoke: agentos rollback ${PROJECT_NAME} --dry-run"
  exit 0
fi

if [[ "${ASSUME_YES}" != "true" ]]; then
  echo "Rolling back will move current -> previous and restart the systemd service."
  echo "If healthcheck fails after rollback, NO automatic recovery (manual intervention required)."
  read -rp "Proceed with rollback? [y/N] " ans
  [[ "${ans}" == "y" || "${ans}" == "Y" ]] || exit 1
fi

"${SSH_BIN}" "${SSH_HOST}" "agentos rollback ${PROJECT_NAME}"
RC=$?
if [[ ${RC} -eq 0 ]]; then
  echo "==> rollback OK"
else
  echo "==> rollback FAILED (rc=${RC})" >&2
fi
exit ${RC}
