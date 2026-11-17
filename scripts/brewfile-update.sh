#!/usr/bin/env bash
# Dump Homebrew inventory into the backup mirror (not the tool repo).
set -euo pipefail

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ENV_HINTS=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
[[ -f "${PROJECT_ROOT}/backup.conf.example" ]] && source "${PROJECT_ROOT}/backup.conf.example"
# shellcheck source=/dev/null
[[ -f "${PROJECT_ROOT}/backup.conf.local" ]] && source "${PROJECT_ROOT}/backup.conf.local"

if [[ -z "${PC_BACKUP_ROOT:-}" ]]; then
  echo "ERROR: PC_BACKUP_ROOT is unset. Set it in backup.conf.local." >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "brew not found" >&2
  exit 1
fi

BREW_DIR="${1:-${PC_BACKUP_ROOT}/mirror/brew}"
BREWFILE="${BREW_DIR}/Brewfile"
mkdir -p "${BREW_DIR}"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pc-backup-brew.XXXXXX")"
cleanup_tmp() { rm -rf "${TMP_DIR}"; }
trap cleanup_tmp EXIT

TMP_BREWFILE="${TMP_DIR}/Brewfile"
TMP_LEAVES="${TMP_DIR}/brew-leaves.txt"
TMP_CASKS="${TMP_DIR}/brew-casks.txt"

echo "Updating ${BREWFILE}"
set +e
brew bundle dump --force --file="${TMP_BREWFILE}"
dump_rc=$?
set -e
if [[ "${dump_rc}" -eq 0 ]]; then
  echo "brew bundle dump succeeded"
else
  echo "brew bundle dump failed (${dump_rc}); generating Brewfile from brew leaves/casks" >&2
  set +e
  {
    echo "# Generated fallback $(date +%Y-%m-%d) — brew bundle dump unavailable"
    while read -r pkg; do
      [[ -n "${pkg}" ]] && echo "brew \"${pkg}\""
    done < <(brew leaves || true)
    while read -r pkg; do
      [[ -n "${pkg}" ]] && echo "cask \"${pkg}\""
    done < <(brew list --cask || true)
  } > "${TMP_BREWFILE}"
  set -e
fi

brew leaves > "${TMP_LEAVES}"
brew list --cask > "${TMP_CASKS}"

cp -f "${TMP_BREWFILE}" "${BREWFILE}"
cp -f "${TMP_LEAVES}" "${BREW_DIR}/brew-leaves.txt"
cp -f "${TMP_CASKS}" "${BREW_DIR}/brew-casks.txt"

echo "Done. $(wc -l < "${BREWFILE}") lines in Brewfile -> ${BREW_DIR}"
