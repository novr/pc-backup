#!/usr/bin/env bash
# Differential backup via rsync mirror + encrypted secrets bundle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_DRY_RUN="${PC_BACKUP_DRY_RUN-}"
# shellcheck source=/dev/null
[[ -f "${PROJECT_ROOT}/backup.conf.example" ]] && source "${PROJECT_ROOT}/backup.conf.example"
# shellcheck source=/dev/null
[[ -f "${PROJECT_ROOT}/backup.conf.local" ]] && source "${PROJECT_ROOT}/backup.conf.local"
[[ -n "${ENV_DRY_RUN}" ]] && PC_BACKUP_DRY_RUN="${ENV_DRY_RUN}"

: "${PC_BACKUP_ENCRYPT_SECRETS:=1}"
: "${PC_BACKUP_ALLOW_PLAINTEXT_SECRETS:=0}"
: "${PC_BACKUP_DRY_RUN:=0}"
: "${PC_BACKUP_RSYNC_DELETE:=0}"

if [[ -z "${PC_BACKUP_ROOT:-}" ]]; then
  echo "ERROR: PC_BACKUP_ROOT is unset. Set it in backup.conf.local." >&2
  exit 1
fi
if ((${#PC_BACKUP_DIRS[@]} == 0)) || ((${#PC_BACKUP_FILES[@]} == 0)); then
  echo "ERROR: PC_BACKUP_DIRS / FILES must be set (see backup.conf.example)." >&2
  exit 1
fi
if ! declare -p PC_BACKUP_DIR_EXCLUDES >/dev/null 2>&1; then
  PC_BACKUP_DIR_EXCLUDES=()
fi

# file: .zshrc -> dotfiles/.zshrc | .a/b -> a/b
# dir:  .config -> config | .a/b -> a/b
mirror_dest_file() {
  local rel="${1#/}"
  if [[ "${rel}" != */* ]]; then
    printf 'dotfiles/%s\n' "${rel}"
  else
    printf '%s\n' "${rel#.}"
  fi
}

mirror_dest_dir() {
  local rel="${1#/}"
  printf '%s\n' "${rel#.}"
}

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
DATE_TAG="$(date +%Y%m%d)"
BACKUP_ROOT="${PC_BACKUP_ROOT}"
# Launchd cannot open existing OneDrive / File Provider inodes (EPERM, com.apple.macl).
# Differential state stays on local disk; each run publishes a new snapshot directory.
LOCAL_MIRROR="${HOME}/Library/Application Support/pc-backup/mirror"
MIRROR="${LOCAL_MIRROR}"
LOG_DIR="${BACKUP_ROOT}/logs"
CHANGES_DIR="${BACKUP_ROOT}/changes"
META_DIR="${MIRROR}/meta"
LOG_FILE="${LOG_DIR}/${TIMESTAMP}.log"
RSYNC_FAILURES=0
WORK_TMP=""

RSYNC_OPTS=(-a --human-readable --itemize-changes)
[[ "${PC_BACKUP_DRY_RUN}" == "1" ]] && RSYNC_OPTS+=(--dry-run)
[[ "${PC_BACKUP_RSYNC_DELETE}" == "1" ]] && RSYNC_OPTS+=(--delete)

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

record_rsync() {
  local src="$1" dest_rel="$2" change_file="$3" rc="$4"
  if [[ "${rc}" -ne 0 ]]; then
    log "WARN: rsync exit ${rc} for ${src}"
    RSYNC_FAILURES=$((RSYNC_FAILURES + 1))
  fi
  if [[ "${PC_BACKUP_DRY_RUN}" == "1" ]]; then
    rm -f "${change_file}"
    return 0
  fi
  if [[ -s "${change_file}" ]]; then
    log "  changes recorded: ${change_file}"
  else
    rm -f "${change_file}"
  fi
}

rsync_path() {
  local src="$1" dest_rel="$2" dest="${MIRROR}/${2}"
  if [[ ! -e "${src}" ]]; then
    log "SKIP (missing): ${src}"
    return 0
  fi
  mkdir -p "$(dirname "${dest}")"
  local change_file="${CHANGES_DIR}/${TIMESTAMP}-${dest_rel//\//_}.txt" rc=0
  log "rsync: ${src} -> mirror/${dest_rel}"
  rsync "${RSYNC_OPTS[@]}" "${src}" "${dest}" > "${change_file}" 2>&1 || rc=$?
  record_rsync "${src}" "${dest_rel}" "${change_file}" "${rc}"
}

# Excludes are home-relative paths under a backed-up directory.
rsync_excludes_for() {
  local rel="$1" ex
  RSYNC_DIR_EXCLUDES=()
  # bash 3.2 + set -u treats "${empty[@]}" as unbound.
  if ((${#PC_BACKUP_DIR_EXCLUDES[@]} == 0)); then
    return 0
  fi
  for ex in "${PC_BACKUP_DIR_EXCLUDES[@]}"; do
    if [[ "${ex}" == "${rel}/"* ]]; then
      RSYNC_DIR_EXCLUDES+=(--exclude="${ex#"${rel}/"}")
    fi
  done
}

rsync_dir() {
  local src="$1" dest_rel="$2" home_rel="$3" dest="${MIRROR}/${2}"
  if [[ ! -d "${src}" ]]; then
    log "SKIP (missing dir): ${src}"
    return 0
  fi
  mkdir -p "${dest}"
  rsync_excludes_for "${home_rel}"
  local change_file="${CHANGES_DIR}/${TIMESTAMP}-${dest_rel//\//_}.txt" rc=0
  log "rsync: ${src}/ -> mirror/${dest_rel}/"
  if ((${#RSYNC_DIR_EXCLUDES[@]})); then
    rsync "${RSYNC_OPTS[@]}" "${RSYNC_DIR_EXCLUDES[@]}" "${src}/" "${dest}/" > "${change_file}" 2>&1 || rc=$?
  else
    rsync "${RSYNC_OPTS[@]}" "${src}/" "${dest}/" > "${change_file}" 2>&1 || rc=$?
  fi
  record_rsync "${src}/" "${dest_rel}" "${change_file}" "${rc}"
}

write_inventory() {
  [[ "${PC_BACKUP_DRY_RUN}" == "1" ]] && return 0
  mkdir -p "${META_DIR}"
  cat > "${META_DIR}/inventory-${DATE_TAG}.json" <<EOF
{
  "timestamp": "${TIMESTAMP}",
  "hostname": "$(hostname)",
  "user": "$(whoami)",
  "dry_run": ${PC_BACKUP_DRY_RUN},
  "encrypt_secrets": ${PC_BACKUP_ENCRYPT_SECRETS}
}
EOF
  cp "${META_DIR}/inventory-${DATE_TAG}.json" "${META_DIR}/inventory-latest.json"
}

backup_secrets_bundle() {
  if ((${#PC_BACKUP_SECRETS[@]} == 0)); then
    log "SKIP secrets (PC_BACKUP_SECRETS empty)"
    return 0
  fi
  require_cmd tar
  local staging="${WORK_TMP}/secrets"
  mkdir -p "${staging}" "${MIRROR}/encrypted"
  local bundle_path="${staging}/secrets.tar"
  local latest_path="${MIRROR}/encrypted/secrets-latest.tar.gpg"
  local plaintext_latest="${MIRROR}/encrypted/secrets-latest.tar"

  log "Building secrets bundle"
  local items=() rel
  for rel in "${PC_BACKUP_SECRETS[@]}"; do
    if [[ -e "${HOME}/${rel}" ]]; then
      items+=("${rel}")
    else
      log "SKIP secret (missing): ${HOME}/${rel}"
    fi
  done
  if [[ ${#items[@]} -eq 0 ]]; then
    log "No secrets paths found; skipping bundle"
    rm -rf "${staging}"
    return 0
  fi

  if [[ "${PC_BACKUP_DRY_RUN}" == "1" ]]; then
    log "DRY-RUN: would pack ${#items[@]} secret path(s)"
    rm -rf "${staging}"
    return 0
  fi

  local -a tar_excludes=(
    --exclude='.ssh/agent'
    --exclude='.ssh/controlmasters'
    --exclude='.gnupg/S.*'
    --exclude='.gnupg/*.socket'
  )
  local sock
  for rel in "${items[@]}"; do
    while IFS= read -r sock; do
      [[ -n "${sock}" ]] || continue
      tar_excludes+=(--exclude="${sock#${HOME}/}")
    done < <(find "${HOME}/${rel}" -type s -print 2>/dev/null || true)
  done

  (
    cd "${HOME}"
    COPYFILE_DISABLE=1 tar -cf "${bundle_path}" "${tar_excludes[@]}" "${items[@]}" 2>>"${LOG_FILE}"
  )

  if [[ "${PC_BACKUP_ENCRYPT_SECRETS}" == "1" ]]; then
    require_cmd gpg
    if [[ -z "${PC_BACKUP_GPG_PASS:-}" ]]; then
      rm -rf "${staging}"
      die "PC_BACKUP_GPG_PASS is unset. Refusing plaintext secrets."
    fi
    local tmp_gpg="${staging}/secrets.tar.gpg"
    printf '%s' "${PC_BACKUP_GPG_PASS}" | gpg --batch --yes --pinentry-mode loopback \
      --passphrase-fd 0 \
      --symmetric --cipher-algo AES256 \
      --output "${tmp_gpg}" "${bundle_path}"
    if ! cp -f "${tmp_gpg}" "${latest_path}"; then
      rm -rf "${staging}"
      die "failed to write ${latest_path}"
    fi
    rm -f "${tmp_gpg}" "${plaintext_latest}"
    log "Encrypted secrets -> mirror/encrypted/secrets-latest.tar.gpg"
  else
    if [[ "${PC_BACKUP_ALLOW_PLAINTEXT_SECRETS}" != "1" ]]; then
      rm -rf "${staging}"
      die "Plaintext secrets refused. Set PC_BACKUP_ALLOW_PLAINTEXT_SECRETS=1 or enable encryption."
    fi
    cp "${bundle_path}" "${plaintext_latest}"
    log "WARN: stored plaintext secrets (explicit allow)"
  fi
  rm -rf "${staging}"
}

prune_changes() {
  [[ "${PC_BACKUP_DRY_RUN}" == "1" ]] && return 0
  find "${CHANGES_DIR}" -type f -name '*.txt' -mtime +30 -delete 2>/dev/null || true
  find "${LOG_DIR}" -type f -name '*.log' -mtime +30 -delete 2>/dev/null || true
  find "${META_DIR}" -type f -name 'inventory-2*.json' -mtime +30 -delete 2>/dev/null || true
}

# New directory of files this process creates. Replacing an existing OneDrive
# inode returns EPERM from LaunchAgents.
publish_snapshot() {
  if [[ "${PC_BACKUP_DRY_RUN}" == "1" ]]; then
    log "DRY-RUN: would publish snapshots/${TIMESTAMP}"
    return 0
  fi
  local incoming="${BACKUP_ROOT}/snapshots/.incoming-${TIMESTAMP}"
  local dest="${BACKUP_ROOT}/snapshots/${TIMESTAMP}"
  rm -rf "${incoming}"
  mkdir -p "${incoming}"
  if ! cp -R "${MIRROR}/." "${incoming}/"; then
    die "failed to publish ${incoming}"
  fi
  printf '%s\n' "${TIMESTAMP}" > "${incoming}/.complete"
  if ! mv "${incoming}" "${dest}"; then
    die "failed to finalize snapshot ${dest}"
  fi
  log "Published snapshot -> snapshots/${TIMESTAMP}"
}

prune_snapshots() {
  [[ "${PC_BACKUP_DRY_RUN}" == "1" ]] && return 0
  [[ -d "${BACKUP_ROOT}/snapshots" ]] || return 0
  local d
  while IFS= read -r d; do
    [[ -n "${d}" ]] || continue
    if rm -rf "${d}"; then
      log "Pruned $(basename "${d}")"
    else
      log "WARN: could not prune ${d}"
    fi
  done < <(find "${BACKUP_ROOT}/snapshots" -mindepth 1 -maxdepth 1 -type d \( -name '20*' -o -name '.incoming-*' \) -mtime +14 -print 2>/dev/null || true)
}

# Emit a bash array assignment with shell-quoted elements.
emit_quoted_array() {
  local name="$1"
  shift
  printf '%s=(\n' "${name}"
  local item
  for item in "$@"; do
    printf '  %q\n' "${item}"
  done
  printf ')\n\n'
}

# Self-contained kit: effective conf + scripts + gpg-pass (not a repo mirror).
sync_tool_kit() {
  local kit="${MIRROR}/tool"
  if [[ "${PC_BACKUP_DRY_RUN}" == "1" ]]; then
    log "DRY-RUN: would sync tool kit -> ${kit}"
    return 0
  fi

  local staging f old_umask
  staging="$(mktemp -d "${TMPDIR:-/tmp}/pc-backup-kit.XXXXXX")"
  mkdir -p "${staging}/scripts" "${kit}/scripts"

  {
    printf '# Generated by backup.sh (effective settings at backup time).\n'
    printf 'PC_BACKUP_ROOT=%q\n\n' "${PC_BACKUP_ROOT}"
    if ((${#PC_BACKUP_DIR_EXCLUDES[@]})); then
      emit_quoted_array PC_BACKUP_DIR_EXCLUDES "${PC_BACKUP_DIR_EXCLUDES[@]}"
    else
      printf 'PC_BACKUP_DIR_EXCLUDES=()\n\n'
    fi
    emit_quoted_array PC_BACKUP_DIRS "${PC_BACKUP_DIRS[@]}"
    emit_quoted_array PC_BACKUP_FILES "${PC_BACKUP_FILES[@]}"
    emit_quoted_array PC_BACKUP_SECRETS "${PC_BACKUP_SECRETS[@]}"
    printf 'PC_BACKUP_ENCRYPT_SECRETS=%q\n' "${PC_BACKUP_ENCRYPT_SECRETS}"
    printf 'PC_BACKUP_ALLOW_PLAINTEXT_SECRETS=%q\n' "${PC_BACKUP_ALLOW_PLAINTEXT_SECRETS}"
    printf 'PC_BACKUP_RSYNC_DELETE=%q\n' "${PC_BACKUP_RSYNC_DELETE}"
    if [[ -n "${PC_BACKUP_GPG_PASS:-}" ]]; then
      # Sourced conf: BASH_SOURCE[0] is this file's path.
      printf '\nPC_BACKUP_GPG_PASS="$(cat "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gpg-pass")"\n'
    fi
  } > "${staging}/backup.conf.local"

  if [[ -n "${PC_BACKUP_GPG_PASS:-}" ]]; then
    old_umask="$(umask)"
    umask 077
    printf '%s' "${PC_BACKUP_GPG_PASS}" > "${staging}/gpg-pass"
    umask "${old_umask}"
    chmod 600 "${staging}/gpg-pass"
    if ! cp -f "${staging}/gpg-pass" "${kit}/gpg-pass"; then
      rm -rf "${staging}"
      die "failed to write ${kit}/gpg-pass"
    fi
    chmod 600 "${kit}/gpg-pass"
  else
    log "WARN: PC_BACKUP_GPG_PASS unset; kit conf has no passphrase binding"
  fi

  if ! cp -f "${staging}/backup.conf.local" "${kit}/backup.conf.local"; then
    rm -rf "${staging}"
    die "failed to write ${kit}/backup.conf.local"
  fi

  shopt -s nullglob
  local scripts=("${SCRIPT_DIR}"/*.sh)
  shopt -u nullglob
  if ((${#scripts[@]} == 0)); then
    rm -rf "${staging}"
    die "no scripts to copy from ${SCRIPT_DIR}"
  fi
  for f in "${scripts[@]}"; do
    cp -f "${f}" "${staging}/scripts/"
  done
  for f in "${staging}/scripts"/*.sh; do
    if ! cp -f "${f}" "${kit}/scripts/"; then
      rm -rf "${staging}"
      die "failed to write ${kit}/scripts/$(basename "${f}")"
    fi
  done
  chmod +x "${kit}/scripts/"*.sh
  rm -rf "${staging}"

  log "Tool kit synced -> ${kit}"
}

main() {
  require_cmd rsync
  mkdir -p "${LOG_DIR}" "${CHANGES_DIR}" "${MIRROR}" "${BACKUP_ROOT}/snapshots"
  chmod 700 "$(dirname "${LOCAL_MIRROR}")" "${LOCAL_MIRROR}"
  WORK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/pc-backup.XXXXXX")"
  trap 'rm -rf "${WORK_TMP}"' EXIT

  log "=== PC backup start ==="
  log "Destination: ${BACKUP_ROOT}"
  [[ "${PC_BACKUP_DRY_RUN}" == "1" ]] && log "Mode: dry-run"

  if [[ -x "${SCRIPT_DIR}/brewfile-update.sh" ]]; then
    if [[ "${PC_BACKUP_DRY_RUN}" == "1" ]]; then
      log "DRY-RUN: would refresh Brewfile"
    else
      local brew_log="${WORK_TMP}/brew.log"
      if "${SCRIPT_DIR}/brewfile-update.sh" "${MIRROR}/brew" >"${brew_log}" 2>&1; then
        log "Brewfile updated"
      else
        log "WARN: brewfile-update failed"
        cat "${brew_log}" >> "${LOG_FILE}" || true
      fi
    fi
  fi

  local rel dest
  for rel in "${PC_BACKUP_FILES[@]}"; do
    dest="$(mirror_dest_file "${rel}")"
    rsync_path "${HOME}/${rel}" "${dest}"
  done
  for rel in "${PC_BACKUP_DIRS[@]}"; do
    dest="$(mirror_dest_dir "${rel}")"
    rsync_dir "${HOME}/${rel}" "${dest}" "${rel}"
  done

  backup_secrets_bundle
  sync_tool_kit
  write_inventory
  publish_snapshot
  prune_changes
  prune_snapshots

  if [[ "${RSYNC_FAILURES}" -gt 0 ]]; then
    die "completed with ${RSYNC_FAILURES} rsync failure(s)"
  fi

  log "=== PC backup complete ==="
  du -sh "${MIRROR}" 2>/dev/null | tee -a "${LOG_FILE}" || true
}

main "$@"
