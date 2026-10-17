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

enable_providers_v2() {
  local log="$1"
  {
    printf '\n--- providers_v2 set ---\n'
    openshell settings set -g nemoclaw --global --key providers_v2_enabled --value true --yes
    printf '\n--- providers_v2 get ---\n'
    openshell settings get -g nemoclaw --global --json || true
  } >>"$log" 2>&1 || true
}

# Drop only an unfinished route reservation. A ready sandbox has no
# pendingRouteReservation, so this leaves it in place. Do not use
# `sandbox destroy`: that also removes the Hermes state volume.
clear_unfinished_route_reservation() {
  local registry="${HOME}/.nemoclaw/sandboxes.json" removed
  [[ -f "$registry" ]] || return 0
  removed="$(python3 - "$registry" "$NEMOCLAW_SANDBOX_NAME" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
with open(path) as handle:
    data = json.load(handle)
sandboxes = data.get("sandboxes") or {}
entry = sandboxes.get(name)
if not isinstance(entry, dict):
    raise SystemExit(0)
if entry.get("pendingRouteReservation") is not True or entry.get("pendingCreateIdentity") is not None:
    raise SystemExit(0)
del sandboxes[name]
data["sandboxes"] = sandboxes
if data.get("defaultSandbox") == name:
    data["defaultSandbox"] = next(iter(sandboxes), None)
with open(path, "w") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
print(f"removed pending route reservation for {name}")
PY
)"
  if [[ "$removed" == removed\ pending\ route\ reservation* ]]; then
    openshell sandbox delete -g nemoclaw "$NEMOCLAW_SANDBOX_NAME" || true
  fi
}

host_onboard_failure() {
  local log="$1" reason
  {
    printf '\n--- openshell status ---\n'
    openshell status || true
  } >>"$log" 2>&1 || true
  reason="$(grep -E 'Error:|×|failed to|did not|Permission denied|not ready|Cannot|providers_v2' "$log" | tail -n 20 || true)"
  die "onboard failed for ${NEMOCLAW_SANDBOX_NAME}. ${reason:-$(tail -c 800 "$log")}"
}

host_onboard_resume_only() {
  local log bin_dir
  log="$(mktemp)"
  mkdir -p "${HOME}/.nemoclaw"
  chmod 700 "${HOME}/.nemoclaw"
  bin_dir="${HOME}/.nemoclaw/openshell/bin"
  if [[ -x "${bin_dir}/openshell" && -x "${bin_dir}/openshell-gateway" ]]; then
    export NEMOCLAW_OPENSHELL_BIN="${bin_dir}/openshell"
    export NEMOCLAW_OPENSHELL_GATEWAY_BIN="${bin_dir}/openshell-gateway"
    export PATH="${bin_dir}:${PATH}"
  fi
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    export DOCKER_CONFIG="$(mktemp -d)"
    printf '%s\n' '{}' >"${DOCKER_CONFIG}/config.json"
    # The CLI only finds mTLS certs via OPENSHELL_LOCAL_TLS_DIR. The gateway
    # writes them under its state dir, which is not the CLI default.
    export OPENSHELL_LOCAL_TLS_DIR="${HOME}/.local/state/nemoclaw/openshell-docker-gateway/tls"
    if [[ ! -w "${HOME}/.config" ]]; then
      die "~/.config is not writable by ${USER}. On the Mac mini run: sudo chown ${USER}:staff ${HOME}/.config && chmod u+rwx ${HOME}/.config"
    fi
  fi
  printf 'starting a new onboarding session for %s\n' "$NEMOCLAW_SANDBOX_NAME"
  clear_unfinished_route_reservation
  if openshell gateway list -o json 2>/dev/null | grep -q '"name": "nemoclaw"'; then
    enable_providers_v2 "$log"
  else
    printf 'gateway nemoclaw is not registered yet; onboard will register it\n'
  fi
  # poc-claw is not ready, so it has no workspace to snapshot. NemoClaw stops
  # the recreate until this is set. One onboard only; a second --fresh sees a
  # different gateway authority and refuses to delete the sandbox.
  if NEMOCLAW_RECREATE_WITHOUT_BACKUP=1 host_nemoclaw_cmd onboard \
    --non-interactive \
    --yes-i-accept-third-party-software \
    --yes \
    --fresh \
    --no-ollama-autostart \
    --agent "$NEMOCLAW_AGENT" \
    --name "$NEMOCLAW_SANDBOX_NAME" >"$log" 2>&1; then
    rm -f "$log"
    return 0
  fi
  host_onboard_failure "$log"
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
