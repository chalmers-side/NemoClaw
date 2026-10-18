#!/usr/bin/env bash
# Deploy one personal_config target, one stage at a time.
# Usage: ./scripts/deploy.sh <target> <ollama|nemoclaw|onboard|upgrade>
#   ollama    host Ollama LaunchAgent + model pull
#   nemoclaw  OpenShell gateway, nemohermes CLI, auth proxy
#   onboard   first sandbox install
#   upgrade   later sandbox redeploy; does not destroy sandbox or gateway
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
ACTION="${2:-}"
[[ -n "$ACTION" ]] || die "usage: $0 <target> <ollama|nemoclaw|onboard|upgrade>"

load_target "$TARGET"
assert_not_actions_worktree
load_secrets
validate_secrets
preflight_host

case "$ACTION" in
  sandbox) ACTION=onboard ;;
esac
case "$ACTION" in
  ollama | nemoclaw | onboard | upgrade) ;;
  *) die "unknown action '${ACTION}' (expected ollama, nemoclaw, onboard, or upgrade)" ;;
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

host_onboard_failure() {
  local log="$1" reason
  {
    printf '\n--- openshell status ---\n'
    openshell status || true
  } >>"$log" 2>&1 || true
  reason="$(grep -E 'Error:|×|failed to|Permission denied|not ready|Cannot|providers_v2' "$log" | grep -v 'Onboarding did not finish' | tail -n 20 || true)"
  die "onboard failed for ${NEMOCLAW_SANDBOX_NAME}. ${reason:-$(tail -c 800 "$log")}"
}

prepare_host_openshell_env() {
  local bin_dir gw_state
  mkdir -p "${HOME}/.nemoclaw"
  chmod 700 "${HOME}/.nemoclaw"
  bin_dir="${HOME}/.nemoclaw/openshell/bin"
  if [[ -x "${bin_dir}/openshell" && -x "${bin_dir}/openshell-gateway" ]]; then
    export NEMOCLAW_OPENSHELL_BIN="${bin_dir}/openshell"
    export NEMOCLAW_OPENSHELL_GATEWAY_BIN="${bin_dir}/openshell-gateway"
    export PATH="${bin_dir}:${PATH}"
  fi
  export PATH="/opt/homebrew/opt/node@22/bin:${HOME}/.local/bin:${PATH}"
  gw_state="${HOME}/.local/state/nemoclaw/openshell-docker-gateway"
  export OPENSHELL_LOCAL_TLS_DIR="${gw_state}/tls"
  if [[ -f "${gw_state}/openshell-gateway.toml" ]]; then
    export OPENSHELL_GATEWAY_CONFIG="${gw_state}/openshell-gateway.toml"
  fi
  if [[ -f "${gw_state}/openshell.db" ]]; then
    export OPENSHELL_DB_URL="sqlite:${gw_state}/openshell.db"
  fi
  export OPENSHELL_SERVER_PORT="${OPENSHELL_SERVER_PORT:-8080}"
  export NEMOCLAW_GATEWAY_PORT="${NEMOCLAW_GATEWAY_PORT:-8080}"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    export DOCKER_CONFIG="$(mktemp -d)"
    printf '%s\n' '{}' >"${DOCKER_CONFIG}/config.json"
    if [[ ! -w "${HOME}/.config" ]]; then
      die "~/.config is not writable by ${USER}. On the Mac mini run: sudo chown ${USER}:staff ${HOME}/.config && chmod u+rwx ${HOME}/.config"
    fi
  fi
}

require_connected_gateway() {
  ensure_recorded_tls_gateway
}

run_host_onboard() {
  local log="$1"
  shift
  if host_nemoclaw_cmd onboard \
    --non-interactive \
    --yes-i-accept-third-party-software \
    --yes \
    "$@" \
    --no-ollama-autostart \
    --agent "$NEMOCLAW_AGENT" \
    --name "$NEMOCLAW_SANDBOX_NAME" >"$log" 2>&1; then
    return 0
  fi
  return 1
}

destroy_sandbox_keep_gateway() {
  local cid
  printf 'destroying sandbox %s; keeping the host gateway\n' "$NEMOCLAW_SANDBOX_NAME"
  cid="$(docker ps -aq --filter "name=openshell-default--${NEMOCLAW_SANDBOX_NAME}" 2>/dev/null || true)"
  cid="${cid%%$'\n'*}"
  if [[ -n "$cid" ]]; then
    docker start "$cid" >/dev/null 2>&1 || true
  fi
  host_nemoclaw_cmd "$NEMOCLAW_SANDBOX_NAME" destroy --yes --no-cleanup-gateway \
    || die "destroy failed for ${NEMOCLAW_SANDBOX_NAME}. Start the sandbox container then rerun. Do not kill -9, and do not omit --no-cleanup-gateway."
}

start_sandbox_container_if_present() {
  local cid
  cid="$(docker ps -aq --filter "name=openshell-default--${NEMOCLAW_SANDBOX_NAME}" 2>/dev/null || true)"
  cid="${cid%%$'\n'*}"
  [[ -n "$cid" ]] || return 1
  docker start "$cid" >/dev/null 2>&1 || true
}

repair_sandbox_boot() {
  start_sandbox_container_if_present || true
  repair_sandbox_openshell_hosts || true
  ensure_openshell_openai_inference || true
  ensure_hermes_inference_placeholder || true
}

repair_sandbox_while_onboard() {
  local i
  for i in $(seq 1 40); do
    repair_sandbox_openshell_hosts || true
    sleep 3
  done
}

host_onboard_resume_only() {
  local log state session extra=() repair_pid=""
  log="$(mktemp)"
  prepare_host_openshell_env
  require_connected_gateway
  ensure_openshell_openai_inference || true
  state="$(classify_host_sandbox)"
  session="$(classify_onboard_session)"
  printf 'sandbox state=%s session=%s\n' "$state" "$session"
  case "$state" in
    ready)
      printf 'sandbox %s is ready; skip onboard\n' "$NEMOCLAW_SANDBOX_NAME"
      rm -f "$log"
      return 0
      ;;
    error)
      if [[ "$session" == "resumable" ]]; then
        printf 'sandbox %s is Error with a resumable session; repair and --resume\n' "$NEMOCLAW_SANDBOX_NAME"
        repair_sandbox_boot
        extra=(--resume)
      else
        printf 'sandbox %s is Error; destroy then onboard\n' "$NEMOCLAW_SANDBOX_NAME"
        destroy_sandbox_keep_gateway
        session="$(classify_onboard_session)"
        case "$session" in
          resumable) extra=(--resume) ;;
          stale) extra=(--fresh) ;;
          *) extra=() ;;
        esac
      fi
      ;;
    absent)
      case "$session" in
        resumable)
          printf 'interrupted onboard; --resume\n'
          extra=(--resume)
          ;;
        stale)
          printf 'stale onboard session and no sandbox; --fresh\n'
          extra=(--fresh)
          ;;
        *)
          printf 'no sandbox; onboard on the Connected gateway\n'
          extra=()
          ;;
      esac
      ;;
    unknown)
      if [[ "$session" == "resumable" ]]; then
        printf 'sandbox state unknown; --resume interrupted onboard\n'
        extra=(--resume)
      else
        die "sandbox ${NEMOCLAW_SANDBOX_NAME} status is not Ready/Error/absent. Inspect it before onboard, destroy, or --fresh."
      fi
      ;;
  esac
  printf 'onboard flags:%s\n' "${extra[*]:+ ${extra[*]}}"
  release_untagged_openshell_gateway
  repair_sandbox_while_onboard &
  repair_pid=$!
  if run_host_onboard "$log" "${extra[@]}"; then
    kill "$repair_pid" 2>/dev/null || true
    wait "$repair_pid" 2>/dev/null || true
    rm -f "$log"
    return 0
  fi
  kill "$repair_pid" 2>/dev/null || true
  wait "$repair_pid" 2>/dev/null || true
  if grep -q 'Agent setup failed' "$log"; then
    printf 'Hermes agent setup failed; repair hosts/inference and --resume\n'
    repair_sandbox_boot
    if run_host_onboard "$log" --resume; then
      rm -f "$log"
      return 0
    fi
  fi
  host_onboard_failure "$log"
}

host_upgrade_sandboxes() {
  local log
  log="$(mktemp)"
  printf 'checking whether %s exists before upgrade\n' "$NEMOCLAW_SANDBOX_NAME"
  host_nemoclaw_cmd "$NEMOCLAW_SANDBOX_NAME" status >"$log" 2>&1 || true
  if grep -F "Sandbox '${NEMOCLAW_SANDBOX_NAME}' does not exist" "$log" >/dev/null; then
    printf 'sandbox %s is not installed; skip upgrade. Run stage sandbox (onboard) once.\n' "$NEMOCLAW_SANDBOX_NAME"
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
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

require_host_ollama() {
  ollama_http_ok || die "Ollama is not up on 127.0.0.1:11434. Run stage ollama first."
}

require_host_nemoclaw() {
  export PATH="/opt/homebrew/opt/node@22/bin:${HOME}/.local/bin:${PATH}"
  if command -v nemohermes >/dev/null 2>&1 && nemohermes --version >/dev/null 2>&1; then
    return 0
  fi
  die "nemohermes is not installed. Run stage nemoclaw first."
}

deploy_host_ollama() {
  printf 'stage ollama for %s\n' "$TARGET"
  ensure_local_llm
  write_stage_marker ollama
  printf 'Ollama is up for %s\n' "$TARGET"
}

deploy_host_nemoclaw() {
  printf 'stage nemoclaw for %s\n' "$TARGET"
  report_docker_desktop_budget
  ensure_homebrew_openshell_gateway
  ensure_host_nemohermes
  install_ollama_auth_proxy_agent
  if [[ -z "${GITHUB_ACTIONS:-}" ]]; then
    install_macos_bridge_boot_daemon
  fi
  write_stage_marker nemoclaw
  printf 'NemoClaw host tools are up for %s\n' "$TARGET"
}

deploy_host_sandbox() {
  require_host_ollama
  require_host_nemoclaw
  case "$ACTION" in
    onboard)
      printf 'stage sandbox onboard for %s\n' "$TARGET"
      host_onboard_resume_only
      verify_sandbox
      write_stage_marker sandbox
      ;;
    upgrade)
      printf 'stage sandbox upgrade for %s\n' "$TARGET"
      if host_upgrade_sandboxes; then
        verify_sandbox
        write_stage_marker sandbox
      fi
      ;;
  esac
  printf 'sandbox stage finished for %s\n' "$TARGET"
}

if ollama_on_host; then
  case "$ACTION" in
    ollama) deploy_host_ollama ;;
    nemoclaw) deploy_host_nemoclaw ;;
    onboard | upgrade) deploy_host_sandbox ;;
  esac
else
  case "$ACTION" in
    ollama)
      printf 'stage ollama (compose) for %s\n' "$TARGET"
      run_compose up -d --build init ollama
      ensure_local_llm
      write_stage_marker ollama
      printf 'compose Ollama is up for %s\n' "$TARGET"
      ;;
    nemoclaw)
      printf 'stage nemoclaw (compose) for %s\n' "$TARGET"
      free_compose_ports
      run_compose up -d --build init gateway
      run_compose up -d --build --force-recreate nemoclaw
      write_stage_marker nemoclaw
      printf 'compose NemoClaw controller started for %s\n' "$TARGET"
      ;;
    onboard | upgrade)
      printf 'stage sandbox (compose) for %s\n' "$TARGET"
      wait_for_controller
      write_stage_marker sandbox
      printf 'compose sandbox stage finished for %s\n' "$TARGET"
      ;;
  esac
fi
