#!/usr/bin/env bash
# Clone or update this repo under /opt/app. Do not deploy from Actions _work.
# Usage: ./scripts/sync-install.sh
# Env: NEMOCLAW_APP (default /opt/app/NemoClaw), NEMOCLAW_REF (default GITHUB_SHA)

set +x
set -euo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

APP_PARENT="/opt/app"
DEST="${NEMOCLAW_APP:-${APP_PARENT}/NemoClaw}"
REF="${NEMOCLAW_REF:-${GITHUB_SHA:-}}"
SRC="${GITHUB_WORKSPACE:-}"
USER_NAME="$(id -un)"
GROUP_NAME="staff"
if [[ "$(uname -s)" != "Darwin" ]]; then
  GROUP_NAME="$(id -gn)"
fi

[[ "$DEST" == "${APP_PARENT}/"* ]] || die "NEMOCLAW_APP must be under /opt/app"
[[ -n "$REF" ]] || die "NEMOCLAW_REF or GITHUB_SHA is required"
[[ -n "$SRC" && -d "${SRC}/.git" ]] || die "GITHUB_WORKSPACE is not a git checkout"

if [[ ! -d "$APP_PARENT" ]]; then
  die "/opt/app does not exist. On this machine run: sudo mkdir -p /opt/app && sudo chown ${USER_NAME}:${GROUP_NAME} /opt/app"
fi
if [[ ! -w "$APP_PARENT" ]]; then
  die "/opt/app is not writable by ${USER_NAME}. Run: sudo chown ${USER_NAME}:${GROUP_NAME} /opt/app"
fi

if [[ ! -d "${DEST}/.git" ]]; then
  if [[ -e "$DEST" ]]; then
    die "${DEST} exists and is not a git clone"
  fi
  printf 'cloning into %s\n' "$DEST"
  git clone "$SRC" "$DEST"
fi

if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  git -C "$DEST" remote set-url origin "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}.git"
fi

printf 'updating %s to %s\n' "$DEST" "$REF"
git -C "$DEST" fetch "$SRC" "$REF"
git -C "$DEST" checkout --force --detach FETCH_HEAD
# Do not git clean. personal_config/*/secrets.env is gitignored and must stay.

for target in poc chalmers cliff; do
  dest_sec="${DEST}/personal_config/${target}/secrets.env"
  src_sec="${HOME}/.nemoclaw/runner-secrets/${target}/secrets.env"
  if [[ ! -f "$dest_sec" && -f "$src_sec" ]]; then
    mkdir -p "$(dirname "$dest_sec")"
    cp "$src_sec" "$dest_sec"
    chmod 600 "$dest_sec"
    printf 'copied runner secrets for %s into the /opt/app tree\n' "$target"
  fi
done

printf 'install tree ready at %s\n' "$DEST"
