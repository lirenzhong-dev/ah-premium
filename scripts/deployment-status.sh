#!/usr/bin/env bash
# RENDERED from ~/AgentOS/deployment/templates/project-scripts/deployment-status.sh.template
# by onboard-project.sh. Do not edit — re-render from the template.

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_NAME="ah-premium"
APP_DIR="/opt/projects/ah-premium"
SSH_HOST="tencent-production"
SSH_BIN="/usr/bin/ssh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-host) SSH_HOST="$2"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

echo "==> ${PROJECT_NAME} production status (via ${SSH_HOST})"
echo
"${SSH_BIN}" "${SSH_HOST}" "agentos status ${PROJECT_NAME}"
