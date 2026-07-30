#!/usr/bin/env bash
# setup-project.sh — per-project setup on the Tencent Cloud server.
# RENDERED from ~/AgentOS/deployment/templates/server-side/setup-project.sh.template
# by onboard-project.sh. Do not edit the rendered copy in a project.
#
# Run as root ONCE per project. Idempotent.
#
# What this does:
#   1. Create /opt/projects/ah-premium/{bin,releases,shared/{uploads,backups,logs}}
#   2. Install the five bin/ scripts (passed via $BIN_DIR or alongside this script)
#   3. Install systemd unit /etc/systemd/system/ah-premium.service
#   4. Add sudoers fragment /etc/sudoers.d/ah-premium-deploy granting the
#      shared `deploy` user passwordless sudo for ONLY this project's commands
#   5. Reload systemd
#
# What this does NOT do:
#   - Create the `deploy` user (bootstrap-server.sh does that, ONCE)
#   - Touch the firewall (no new ports are opened)
#   - Modify any other project's files
#   - Populate /opt/projects/ah-premium/shared/.env (admin does that)

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_NAME="ah-premium"
APP_DIR="/opt/projects/ah-premium"
DEPLOY_USER="deploy"
SERVICE_NAME="ah-premium"

# The five bin scripts are expected alongside this script in $BIN_DIR.
# Default: the directory this script lives in.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${BIN_DIR:-${SCRIPT_DIR}}"

RELEASES_DIR="${APP_DIR}/releases"
SHARED_DIR="${APP_DIR}/shared"
SHARED_UPLOADS="${SHARED_DIR}/uploads"
SHARED_BACKUPS="${SHARED_DIR}/backups"
SHARED_LOGS="${SHARED_DIR}/logs"
SUDOERS_FILE="/etc/sudoers.d/${PROJECT_NAME}-deploy"

# This script needs root to create /opt/projects/<project>/. If not root, try sudo.
if [[ "${EUID}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    echo "Re-executing with sudo..."
    exec sudo --preserve-env=PROJECT_NAME,APP_DIR,DEPLOY_USER,SERVICE_NAME,BIN_DIR "${BASH_SOURCE[0]}" "$@"
  fi
  echo "ERROR: must be root or have sudo" >&2
  exit 1
fi

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
require_cmd systemctl
require_cmd visudo
require_cmd install

# Template inputs become filesystem paths and sudoers entries.  Keep their
# grammar deliberately narrow so a project can never escape its own directory
# or create an arbitrary systemd/sudoers target.
if [[ ! "${PROJECT_NAME}" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; then
  echo "ERROR: invalid project name: ${PROJECT_NAME}" >&2
  exit 1
fi
if [[ "${APP_DIR}" != "/opt/projects/${PROJECT_NAME}" ]]; then
  echo "ERROR: APP_DIR must be exactly /opt/projects/${PROJECT_NAME}" >&2
  exit 1
fi
if [[ "${SERVICE_NAME}" != "${PROJECT_NAME}" ]]; then
  echo "ERROR: SERVICE_NAME must match PROJECT_NAME" >&2
  exit 1
fi

# Safety: refuse to bootstrap if the shared `deploy` user doesn't exist.
if ! id -u "${DEPLOY_USER}" >/dev/null 2>&1; then
  echo "ERROR: system user '${DEPLOY_USER}' does not exist." >&2
  echo "       Run 'ctl.sh bootstrap-server' on the Mac and execute the generated" >&2
  echo "       script as root on the server FIRST." >&2
  exit 1
fi

# Safety: refuse to touch laozi.
case "${APP_DIR}" in
  /opt/laozi-persona-lab|*/laozi-persona-lab)
    echo "ERROR: refusing to set up laozi-persona-lab through this system." >&2
    echo "       laozi is managed by its own existing setup; do not use AgentOS for it." >&2
    exit 1
    ;;
esac

# Safety: refuse to use a port that laozi is already using.
if [[ -f /opt/laozi-persona-lab/.env ]] && grep -qE "PORT=4310" /opt/laozi-persona-lab/.env 2>/dev/null; then
  if [[ "4415" == "4310" ]]; then
    echo "ERROR: APP_PORT=4310 is owned by the existing laozi service." >&2
    echo "       Pick a different port in deployment/project-config.yml." >&2
    exit 1
  fi
fi

echo "==> 1/5 create /opt/projects/${PROJECT_NAME}/"
mkdir -p "${APP_DIR}/bin" "${RELEASES_DIR}" "${SHARED_UPLOADS}" "${SHARED_BACKUPS}" "${SHARED_LOGS}"
# The deploy account may write runtime data only.  It must never be able to
# replace a sudo-allowlisted program in bin/.
chown root:root "${APP_DIR}" "${APP_DIR}/bin"
chmod 0755 "${APP_DIR}" "${APP_DIR}/bin"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${RELEASES_DIR}" "${SHARED_DIR}"
chmod 700 "${SHARED_DIR}"

echo "==> 2/5 install bin/ scripts from ${BIN_DIR}/"
for fname in lib.sh deploy rollback status healthcheck cleanup; do
  src="${BIN_DIR}/${fname}"
  if [[ ! -f "${src}" ]]; then
    echo "ERROR: missing bin script: ${src}" >&2
    exit 1
  fi
  install -m 0755 -o root -g root "${src}" "${APP_DIR}/bin/${fname}"
done

echo "==> 3/5 systemd unit /etc/systemd/system/${SERVICE_NAME}.service"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=${PROJECT_NAME} (managed by AgentOS deployment)
After=network.target

[Service]
Type=simple
User=${DEPLOY_USER}
Group=${DEPLOY_USER}
WorkingDirectory=${APP_DIR}/current/.
EnvironmentFile=-${SHARED_DIR}/.env
ExecStart=/usr/bin/env bash -c 'python3 -m http.server 4415 --bind 127.0.0.1 --directory .'
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true
ReadWritePaths=${SHARED_UPLOADS} ${SHARED_LOGS} ${SHARED_BACKUPS}

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"

echo "==> 4/5 sudoers fragment (deploy user can sudo ONLY this project's commands)"
# Idempotent: write the file fresh each run; it's an exact allowlist.
cat > "${SUDOERS_FILE}" <<EOF
# Managed by setup-project.sh for ${PROJECT_NAME} — do not edit by hand.
# Grants the shared '${DEPLOY_USER}' user passwordless sudo for ONLY this project.
Defaults:${DEPLOY_USER} !requiretty
${DEPLOY_USER} ALL=(root) NOPASSWD: ${APP_DIR}/bin/deploy
${DEPLOY_USER} ALL=(root) NOPASSWD: ${APP_DIR}/bin/rollback
${DEPLOY_USER} ALL=(root) NOPASSWD: ${APP_DIR}/bin/status
${DEPLOY_USER} ALL=(root) NOPASSWD: ${APP_DIR}/bin/healthcheck
${DEPLOY_USER} ALL=(root) NOPASSWD: ${APP_DIR}/bin/cleanup
EOF
chmod 0440 "${SUDOERS_FILE}"
visudo -c -f "${SUDOERS_FILE}" >/dev/null

echo "==> 5/5 done"
echo
cat <<EOF

============================================================
Per-project setup complete for ${PROJECT_NAME}.
Verified sudo grants for ${DEPLOY_USER}:
EOF
sudo -l -U "${DEPLOY_USER}" 2>/dev/null | sed 's/^/  /'
echo
cat <<EOF
Next MANUAL steps (still on the server, as root):
  1. Populate ${APP_DIR}/shared/.env from ${APP_DIR}/shared/.env.example (or your .env.example):
        sudo cp /opt/projects/${PROJECT_NAME}/.env.example ${APP_DIR}/shared/.env
        sudo chmod 600 ${APP_DIR}/shared/.env
        sudo \$EDITOR ${APP_DIR}/shared/.env
  2. Configure Caddy/Nginx to reverse-proxy to http://127.0.0.1:4415/index.html (host:port).
  3. First dry-run from your Mac:
        cd <project-repo>
        ~/AgentOS/deployment/scripts/ctl.sh deploy --dry-run
  4. First real deploy:
        ~/AgentOS/deployment/scripts/ctl.sh deploy
============================================================
EOF
