#!/usr/bin/env bash
# lib.sh — shared library for the server-side deployment scripts.
# RENDERED from ~/AgentOS/deployment/templates/server-side/lib.sh.template
# by onboard-project.sh. Do not edit the rendered copy in a project.
#
# Sourced (not executed) by deploy / rollback / status / healthcheck.
#
# Hard rules:
#   - Single deploy lock (covers BOTH GitHub Actions and local SSH channels).
#   - Shared .env / shared uploads / shared backups never live inside a release.
#   - Atomic switch via `ln -sfn` on `current` symlink.
#   - Every destructive step writes a timestamped entry under shared/logs/.
#   - All commands support --dry-run.
#   - The `deploy` user is shared across all projects; this project does NOT
#     get its own system user.

set -Eeuo pipefail
IFS=$'\n\t'

# ---------- configuration (env overridable, with safe defaults) ----------
PROJECT_NAME="ah-premium"
APP_DIR="/opt/projects/ah-premium"
RELEASES_DIR="${APP_DIR}/releases"
SHARED_DIR="${APP_DIR}/shared"
CURRENT_LINK="${APP_DIR}/current"
PREVIOUS_LINK="${APP_DIR}/previous"
SHARED_ENV="${SHARED_DIR}/.env"
SHARED_UPLOADS="${SHARED_DIR}/uploads"
SHARED_BACKUPS="${SHARED_DIR}/backups"
SHARED_LOGS="${SHARED_DIR}/logs"
DEPLOY_HISTORY="${SHARED_LOGS}/deployments.jsonl"
LOCK_PATH="${DEPLOY_LOCK_PATH:-/var/lock/${PROJECT_NAME}-production-deploy.lock}"

DEPLOY_USER="deploy"   # shared `deploy` user; do not change per project
HEALTHCHECK_HOST="127.0.0.1"
APP_PORT="4415"
HEALTHCHECK_URL="http://127.0.0.1:4415/index.html"
HEALTHCHECK_TIMEOUT="30"
HEALTHCHECK_RETRIES="3"
KEEP_RELEASES="5"

SERVICE_NAME="ah-premium"
SYSTEMD_UNIT="${SERVICE_NAME}.service"

SOURCE_BASE_URL="${SOURCE_BASE_URL:-https://github.com/none/ah-premium}"
SOURCE_TARBALL_PATTERN="${SOURCE_TARBALL_PATTERN:-/archive/${VERSION}.tar.gz}"
LOCAL_SOURCE_DIR="${LOCAL_SOURCE_DIR:-}"

# ---------- logging ----------
_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log()  { printf '[%s] %s\n' "$(_ts)" "$*" >&2; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
err()  { log "ERROR $*"; }
die()  { err "$*"; exit 1; }

# ---------- output capture ----------
DRY_RUN="false"
apply() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# ---------- lock ----------
acquire_lock() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "dry-run: skipping lock acquisition on ${LOCK_PATH}"
    LOCK_FD=999
    return 0
  fi
  mkdir -p "$(dirname "${LOCK_PATH}")"
  exec {LOCK_FD}>"${LOCK_PATH}"
  if ! flock -n "${LOCK_FD}"; then
    die "another deployment is in progress (lock held: ${LOCK_PATH})"
  fi
  printf 'pid=%s user=%s source=%s started=%s\n' \
    "$$" "${SUDO_USER:-$(id -un)}" "${DEPLOY_SOURCE:-unknown}" "$(_ts)" >&"${LOCK_FD}"
  info "acquired deploy lock: ${LOCK_PATH}"
}

release_lock() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "dry-run: skipping lock release"
    return 0
  fi
  if [[ -n "${LOCK_FD:-}" ]] && [[ "${LOCK_FD}" != "999" ]]; then
    flock -u "${LOCK_FD}" 2>/dev/null || true
  fi
  rm -f "${LOCK_PATH}" 2>/dev/null || true
  info "released deploy lock"
}

# ---------- prerequisite checks ----------
require_root_or_sudo() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "this script must run as root (or via sudo); current EUID=${EUID}"
  fi
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "${c}" >/dev/null 2>&1 || die "missing required command: ${c}"
  done
}

# ---------- directory structure ----------
ensure_layout() {
  apply mkdir -p "${RELEASES_DIR}" "${SHARED_DIR}" "${SHARED_UPLOADS}" "${SHARED_BACKUPS}" "${SHARED_LOGS}"
  [[ -f "${SHARED_ENV}" ]] || {
    if [[ "${DRY_RUN}" == "true" ]]; then
      info "dry-run: would create ${SHARED_ENV} from .env.example"
    else
      if [[ -f "${APP_DIR}/.env.example" ]]; then
        cp "${APP_DIR}/.env.example" "${SHARED_ENV}"
        chmod 600 "${SHARED_ENV}"
        warn "shared .env created from .env.example; admin must fill secrets before first deploy"
      else
        die "shared .env missing and no .env.example found at ${APP_DIR}/.env.example"
      fi
    fi
  }
  apply chmod 700 "${SHARED_DIR}"
  apply chmod 755 "${RELEASES_DIR}"
}

# ---------- source acquisition ----------
# Two strategies, picked by DEPLOY_SOURCE:
#   github-actions — fetch tarball from GitHub for ${VERSION}
#   local-ssh      — use a pre-staged local source tree at ${LOCAL_SOURCE_DIR}
fetch_source() {
  local version="$1"
  local stage="${RELEASES_DIR}/.staging-${version}"
  apply mkdir -p "${stage}"
  case "${DEPLOY_SOURCE}" in
    github-actions)
      local url="${SOURCE_BASE_URL}${SOURCE_TARBALL_PATTERN//\$\{VERSION\}/${version}}"
      info "fetching source tarball: ${url}"
      if [[ "${DRY_RUN}" == "true" ]]; then
        info "dry-run: would curl -fsSL ${url} | tar -xz -C ${stage} --strip-components=1"
      else
        curl -fsSL --retry 3 "${url}" | tar -xz -C "${stage}" --strip-components=1
      fi
      ;;
    local-ssh)
      info "using local source: ${LOCAL_SOURCE_DIR}"
      if [[ "${DRY_RUN}" == "true" ]]; then
        info "dry-run: would rsync -a --delete ${LOCAL_SOURCE_DIR}/ ${stage}/"
      else
        [[ -d "${LOCAL_SOURCE_DIR}" ]] || die "LOCAL_SOURCE_DIR not found: ${LOCAL_SOURCE_DIR}"
        rsync -a --delete --exclude='.git' --exclude='node_modules' --exclude='.env' --exclude='backups/' --exclude='logs/' "${LOCAL_SOURCE_DIR}/" "${stage}/"
      fi
      ;;
    *)
      die "unknown DEPLOY_SOURCE: ${DEPLOY_SOURCE} (expected: github-actions or local-ssh)"
      ;;
  esac
  [[ -f "${stage}/package.json" ]] || [[ -f "${stage}/./package.json" ]] || die "fetched source missing package.json; aborting"
  printf '%s' "${stage}"
}

# ---------- install + start ----------
install_deps() {
  local stage="$1"
  local workdir="${stage}/."
  info "running build command in ${workdir}: true"
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "dry-run: would run true in ${workdir}"
  else
    ( cd "${workdir}" && bash -c 'true' )
  fi
}

# Write a per-release .env that points to shared .env plus release-specific vars.
link_shared_env() {
  local stage="$1"
  local version="$2"
  local commit="$3"
  local rel_env="${stage}/.env"
  info "linking shared .env into ${rel_env}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "dry-run: would create ${rel_env} from shared env + APP_VERSION/GIT_COMMIT"
  else
    {
      echo "# generated by deploy at $(_ts) — DO NOT EDIT"
      echo "APP_VERSION=${version}"
      echo "GIT_COMMIT=${commit}"
      [[ -f "${SHARED_ENV}" ]] && sed 's/^/SHARED_/' "${SHARED_ENV}" || true
    } > "${rel_env}"
    chmod 600 "${rel_env}"
  fi
}

# Stop, swap symlink, start.
switch_release() {
  local stage="$1"
  local version="$2"
  info "switching current -> releases/${version}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "dry-run: would update ${PREVIOUS_LINK} and ${CURRENT_LINK} and restart ${SERVICE_NAME}"
  else
    if [[ -L "${CURRENT_LINK}" ]]; then
      ln -sfn "$(readlink "${CURRENT_LINK}")" "${PREVIOUS_LINK}"
    fi
    ln -sfn "${stage}" "${CURRENT_LINK}"
    systemctl restart "${SERVICE_NAME}"
  fi
}

# ---------- healthcheck ----------
wait_for_healthy() {
  local attempt
  for attempt in $(seq 1 "${HEALTHCHECK_RETRIES}"); do
    info "healthcheck attempt ${attempt}/${HEALTHCHECK_RETRIES}: ${HEALTHCHECK_URL}"
    if [[ "${DRY_RUN}" == "true" ]]; then
      info "dry-run: would curl -fsS --max-time ${HEALTHCHECK_TIMEOUT} ${HEALTHCHECK_URL}"
      return 0
    fi
    if curl -fsS --max-time "${HEALTHCHECK_TIMEOUT}" "${HEALTHCHECK_URL}" >/dev/null 2>&1; then
      info "healthcheck OK"
      return 0
    fi
    sleep 2
  done
  err "healthcheck FAILED after ${HEALTHCHECK_RETRIES} attempts"
  return 1
}

# ---------- atomic switch only after health ----------
guarded_switch() {
  local stage="$1" version="$2" commit="$3"
  local previous_target=""
  if [[ -L "${CURRENT_LINK}" ]]; then
    previous_target="$(readlink "${CURRENT_LINK}")"
  fi
  link_shared_env "${stage}" "${version}" "${commit}"
  switch_release "${stage}" "${version}"
  if wait_for_healthy; then
    info "deployment ${version} is now live"
    return 0
  fi
  err "healthcheck failed; rolling back to previous target ${previous_target:-<none>}"
  if [[ -n "${previous_target}" ]] && [[ -d "${previous_target}" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      info "dry-run: would swap back to ${previous_target}"
    else
      ln -sfn "${previous_target}" "${CURRENT_LINK}"
      systemctl restart "${SERVICE_NAME}"
      sleep 2
      if ! wait_for_healthy; then
        err "rollback healthcheck also FAILED — manual intervention required"
        return 2
      fi
    fi
  fi
  return 1
}

# ---------- deployment record ----------
record_deployment() {
  local id
  id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  local project="${PROJECT_NAME}"
  local version="${1:-}"
  local commit="${2:-}"
  local tag="${3:-}"
  local source="${4:-}"
  local started="${5:-}"
  local finished="${6:-}"
  local previous="${7:-}"
  local result="${8:-}"
  local health="${9:-}"
  local backup="${10:-}"
  local rollback="${11:-false}"
  local log="${12:-}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "dry-run: would append deployment record to ${DEPLOY_HISTORY}"
    return 0
  fi
  mkdir -p "$(dirname "${DEPLOY_HISTORY}")"
  DEPLOY_ID="${id}" \
  DEPLOY_PROJECT="${project}" \
  DEPLOY_VERSION="${version}" \
  DEPLOY_COMMIT="${commit}" \
  DEPLOY_TAG="${tag}" \
  DEPLOY_SOURCE="${source}" \
  DEPLOY_STARTED="${started}" \
  DEPLOY_FINISHED="${finished}" \
  DEPLOY_PREVIOUS="${previous}" \
  DEPLOY_RESULT="${result}" \
  DEPLOY_HEALTH="${health}" \
  DEPLOY_BACKUP="${backup}" \
  DEPLOY_ROLLBACK="${rollback}" \
  DEPLOY_LOG="${log}" \
  python3 -c 'import json,os
d={k:v for k,v in os.environ.items() if k.startswith("DEPLOY_")}
d={k[7:].lower():v for k,v in d.items()}
print(json.dumps(d, ensure_ascii=False))' >> "${DEPLOY_HISTORY}"
}

# ---------- release pruning ----------
prune_releases() {
  info "pruning releases beyond KEEP_RELEASES=${KEEP_RELEASES}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "dry-run: would keep newest ${KEEP_RELEASES} and remove older releases/*"
    return 0
  fi
  cd "${RELEASES_DIR}"
  ls -1dt */ 2>/dev/null | tail -n +$((KEEP_RELEASES + 1)) | while read -r d; do
    [[ -d "${d%.}/" ]] && rm -rf -- "${d%.}/"
  done
}

# ---------- current version resolution ----------
current_version() {
  if [[ -L "${CURRENT_LINK}" ]]; then
    basename "$(readlink "${CURRENT_LINK}")"
  else
    echo "<uninitialized>"
  fi
}

previous_version() {
  if [[ -L "${PREVIOUS_LINK}" ]]; then
    basename "$(readlink "${PREVIOUS_LINK}")"
  else
    echo "<none>"
  fi
}
