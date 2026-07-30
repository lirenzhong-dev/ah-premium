#!/usr/bin/env bash
# RENDERED from ~/AgentOS/deployment/templates/project-scripts/deploy-local.sh.template
# by onboard-project.sh. Do not edit — re-render from the template.

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_NAME="ah-premium"
APP_DIR="/opt/projects/ah-premium"
APP_PORT="4415"
SSH_HOST="tencent-production"
SSH_BIN="/usr/bin/ssh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DRY_RUN="false"
ASSUME_YES="false"
VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift ;;
    --yes|-y)  ASSUME_YES="true"; shift ;;
    --version) VERSION="$2"; shift 2 ;;
    --ssh-host) SSH_HOST="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

command -v git >/dev/null 2>&1 || { echo "missing: git" >&2; exit 1; }
command -v "${SSH_BIN}" >/dev/null 2>&1 || { echo "missing: ssh" >&2; exit 1; }

cd "${REPO_ROOT}"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git repo: ${REPO_ROOT}" >&2; exit 1; }

if [[ -z "${VERSION}" ]]; then
  VERSION="$(git rev-parse HEAD)"
fi
if [[ "${VERSION}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  SHA="$(git rev-parse "${VERSION}^{commit}" 2>/dev/null || true)"
  if [[ -z "${SHA}" ]]; then
    git fetch --tags >/dev/null 2>&1 || true
    SHA="$(git rev-parse "${VERSION}^{commit}" 2>/dev/null || true)"
  fi
  [[ -n "${SHA}" ]] || { echo "tag not found: ${VERSION}" >&2; exit 1; }
  VERSION="${SHA}"
  echo "resolved ${VERSION}"
fi

BRANCH="$(git branch --show-current 2>/dev/null || echo detached)"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "warning: working tree has uncommitted changes" >&2
  if [[ "${ASSUME_YES}" != "true" ]]; then
    read -rp "Continue anyway? [y/N] " ans
    [[ "${ans}" == "y" || "${ans}" == "Y" ]] || exit 1
  fi
fi

echo "==> ${PROJECT_NAME} deploy"
echo "    repo:    ${REPO_ROOT}"
echo "    branch:  ${BRANCH}"
echo "    version: ${VERSION}"
echo "    channel: local-ssh"
echo "    target:  ${SSH_HOST}:${SERVER_BIN}"
echo "    dry-run: ${DRY_RUN}"

if [[ "${ASSUME_YES}" != "true" ]] && [[ "${DRY_RUN}" != "true" ]]; then
  read -rp "Proceed with deployment? [y/N] " ans
  [[ "${ans}" == "y" || "${ans}" == "Y" ]] || exit 1
fi

SHA="${VERSION}"
REMOTE_CMD="agentos deploy ${PROJECT_NAME} ${SHA} github-actions"
[[ "${DRY_RUN}" == "true" ]] && REMOTE_CMD+=" --dry-run"
"${SSH_BIN}" "${SSH_HOST}" "${REMOTE_CMD}"
RC=$?

if [[ ${RC} -eq 0 ]]; then
  echo
  echo "==> deploy OK"
else
  echo
  echo "==> deploy FAILED (rc=${RC})" >&2
  echo "    see server log: ssh ${SSH_HOST} 'sudo tail -n 200 ${APP_DIR}/shared/logs/*.log'" >&2
fi
exit ${RC}
