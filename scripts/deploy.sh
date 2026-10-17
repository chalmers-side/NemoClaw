#!/usr/bin/env bash
# Deploy the NemoClaw compose stack for one personal_config target.
# Usage: ./scripts/deploy.sh <target> [onboard|upgrade]
#
# Secrets are read from personal_config/<target>/secrets.env (gitignored).
# Do not enable xtrace; keys must not enter logs.

set +x
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

trap unset_secrets EXIT

TARGET="${1:-}"
ACTION="${2:-onboard}"

load_target "$TARGET"
load_secrets
validate_secrets
preflight_host

case "$ACTION" in
  onboard | upgrade) ;;
  *) die "unknown action '${ACTION}' (expected onboard or upgrade)" ;;
esac

# shellcheck source=scripts/ensure-local-llm.sh
source "${SCRIPT_DIR}/ensure-local-llm.sh"

NEMOCLAW_ACTION="$ACTION"
export NEMOCLAW_ACTION

ensure_host_nemohermes() {
  local pin src log prefix
  export PATH="/opt/homebrew/opt/node@22/bin:${HOME}/.local/bin:${PATH}"
  if command -v nemohermes >/dev/null 2>&1 && nemohermes --version >/dev/null 2>&1; then
    return 0
  fi
  ensure_node_for_auth_proxy
  export PATH="/opt/homebrew/opt/node@22/bin:${HOME}/.local/bin:${PATH}"
  command -v npm >/dev/null 2>&1 || die "npm is required to install nemohermes"
  pin="1e82499a048d5a4d85b0876d8c07bd93c8a9a5de"
  src="${HOME}/.nemoclaw/source"
  log="${HOME}/Library/Logs/nemoclaw-cli-install.log"
  prefix="${HOME}/.local"
  mkdir -p "${HOME}/Library/Logs" "$prefix"
  if [[ ! -d "${src}/.git" ]]; then
    rm -rf "$src"
    mkdir -p "$src"
    git -C "$src" init -q
    git -C "$src" remote add origin https://github.com/NVIDIA/NemoClaw.git
    GIT_TERMINAL_PROMPT=0 git -C "$src" fetch --depth 1 origin "$pin" \
      || die "could not fetch NemoClaw ${pin}"
    git -C "$src" checkout --detach FETCH_HEAD
  fi
  (
    cd "$src"
    export NEMOCLAW_INSTALLING=1
    export NEMOCLAW_AGENT=hermes
    export npm_config_prefix="$prefix"
    node scripts/lib/openshell-sdk-install.mts prepare
    npm install --ignore-scripts --include=optional --@nvidia:registry=https://npm.pkg.github.com
    node scripts/lib/openshell-sdk-install.mts check
    npm run --if-present build:cli
    (cd nemoclaw && npm ci --ignore-scripts && npm run build)
    npm link --ignore-scripts
  ) >"$log" 2>&1 || die "nemohermes install failed. $(tail -n 40 "$log" | grep -v -i -E 'authToken|authorization|bearer' || true)"
  export PATH="${prefix}/bin:${PATH}"
  command -v nemohermes >/dev/null 2>&1 \
    || die "nemohermes install finished but the binary is not on PATH"
}

host_onboard_resume_only() {
  local log
  log="$(mktemp)"
  mkdir -p "${HOME}/.nemoclaw"
  chmod 700 "${HOME}/.nemoclaw"
  printf 'onboarding %s with --resume\n' "$NEMOCLAW_SANDBOX_NAME"
  if host_nemoclaw_cmd onboard \
    --non-interactive \
    --yes-i-accept-third-party-software \
    --yes \
    --resume \
    --no-ollama-autostart \
    --agent "$NEMOCLAW_AGENT" \
    --name "$NEMOCLAW_SANDBOX_NAME" >"$log" 2>&1; then
    rm -f "$log"
    return 0
  fi
  if grep -q "No resumable onboarding session was found." "$log"; then
    printf 'no interrupted session; onboarding %s without --fresh\n' "$NEMOCLAW_SANDBOX_NAME"
    if host_nemoclaw_cmd onboard \
      --non-interactive \
      --yes-i-accept-third-party-software \
      --yes \
      --no-ollama-autostart \
      --agent "$NEMOCLAW_AGENT" \
      --name "$NEMOCLAW_SANDBOX_NAME" >"$log" 2>&1; then
      rm -f "$log"
      return 0
    fi
  fi
  die "onboard failed for ${NEMOCLAW_SANDBOX_NAME}; refusing --fresh. $(tail -n 40 "$log" | sed -E 's/((TOKEN|SECRET|API_KEY|AUTHORIZATION|BEARER|PASSWORD)[=:][[:space:]]*)[^[:space:]]+/\1[redacted]/Ig')"
}

host_upgrade_sandboxes() {
  printf 'upgrading sandboxes; Hermes state volume is left in place\n'
  host_nemoclaw_cmd upgrade-sandboxes --check || true
}

wait_for_controller() {
  local i
  printf 'waiting for NemoClaw controller (first image build + onboard can take a while)\n'
  for i in $(seq 1 180); do
    if run_compose exec -T nemoclaw test -f /root/.nemoclaw-compose-ref >/dev/null 2>&1; then
      if verify_sandbox; then
        return 0
      fi
    fi
    sleep 10
  done
  run_compose logs --tail 120 nemoclaw >&2 || true
  die "NemoClaw controller did not finish onboard for ${NEMOCLAW_SANDBOX_NAME}"
}

if ollama_on_host; then
  printf 'starting host Ollama path for %s (%s)\n' "$TARGET" "$ACTION"
  report_docker_desktop_budget
  ensure_homebrew_openshell_gateway
  ensure_local_llm
  ensure_host_nemohermes
  install_ollama_auth_proxy_agent
  install_macos_bridge_boot_daemon
  case "$ACTION" in
    onboard) host_onboard_resume_only ;;
    upgrade) host_upgrade_sandboxes ;;
  esac
  verify_sandbox
  printf 'host stack is up for %s\n' "$TARGET"
else
  free_compose_ports
  printf 'starting compose stack for %s (%s)\n' "$TARGET" "$ACTION"
  run_compose up -d --build init gateway ollama
  ensure_local_llm
  run_compose up -d --build --force-recreate nemoclaw
  wait_for_controller
  printf 'compose stack is up for %s\n' "$TARGET"
fi
