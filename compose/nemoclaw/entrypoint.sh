#!/usr/bin/env bash
# NemoClaw controller: talk to the compose OpenShell gateway + Ollama.
# Never enable xtrace; credentials must not enter logs.

set +x
set -euo pipefail

export PATH="/usr/local/bin:/root/.local/bin:${PATH}"
export NEMOCLAW_OPENSHELL_BIN="${NEMOCLAW_OPENSHELL_BIN:-/usr/local/bin/openshell}"
export NEMOCLAW_DEFER_OPENSHELL_INSTALL="${NEMOCLAW_DEFER_OPENSHELL_INSTALL:-1}"
export NEMOCLAW_NON_INTERACTIVE="${NEMOCLAW_NON_INTERACTIVE:-1}"
export NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE="${NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE:-1}"

if [[ $# -ge 1 ]]; then
  ACTION="$1"
else
  ACTION="${NEMOCLAW_ACTION:-serve}"
fi
GATEWAY_UPSTREAM=""
OLLAMA_UPSTREAM=""

log() {
  printf 'nemoclaw: %s\n' "$*"
}

die() {
  printf 'nemoclaw: error: %s\n' "$*" >&2
  exit 1
}

cli_name() {
  case "${NEMOCLAW_AGENT:-openclaw}" in
    hermes) printf '%s\n' nemohermes ;;
    langchain-deepagents-code) printf '%s\n' nemo-deepagents ;;
    *) printf '%s\n' nemoclaw ;;
  esac
}

cli() {
  local bin
  bin="$(cli_name)"
  command -v "$bin" >/dev/null || die "${bin} is not installed yet"
  command "$bin" "$@"
}

http_ok() {
  curl -fsS --max-time 2 "$1" >/dev/null 2>&1
}

# OpenShell's HTTP mux returns 404 on GET /. That still means the gateway is up.
http_up() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 "$1" 2>/dev/null || true)"
  [[ "$code" =~ ^[234][0-9][0-9]$ ]]
}

pick_upstream() {
  local port="$1"
  local path="${2:-/}"
  local probe="${3:-http_up}"
  if "$probe" "http://127.0.0.1:${port}${path}"; then
    printf '%s\n' "127.0.0.1"
    return 0
  fi
  if "$probe" "http://gateway:${port}${path}"; then
    printf '%s\n' gateway
    return 0
  fi
  if "$probe" "http://host.docker.internal:${port}${path}"; then
    printf '%s\n' host.docker.internal
    return 0
  fi
  return 1
}

start_socat() {
  local listen_port="$1"
  local upstream_host="$2"
  local upstream_port="$3"
  socat TCP-LISTEN:"${listen_port}",bind=127.0.0.1,fork,reuseaddr \
    TCP:"${upstream_host}:${upstream_port}" &
}

wait_for() {
  local label="$1"
  local attempts="$2"
  shift 2
  local i
  for i in $(seq 1 "$attempts"); do
    if "$@"; then
      return 0
    fi
    sleep 2
  done
  die "${label} did not become ready"
}

prepare_loopback() {
  local i
  log "waiting for OpenShell gateway"
  for i in $(seq 1 45); do
    if GATEWAY_UPSTREAM="$(pick_upstream 8081 /healthz || pick_upstream 8081 /readyz || pick_upstream 8080 /)"; then
      break
    fi
    GATEWAY_UPSTREAM=""
    sleep 2
  done
  [[ -n "$GATEWAY_UPSTREAM" ]] || die "OpenShell gateway is not reachable from this container"
  # When we share the gateway net/pid namespace, 127.0.0.1:8080 is already
  # openshell-gateway. Never front it with socat — onboard rejects that owner.
  if [[ "$GATEWAY_UPSTREAM" != "127.0.0.1" ]]; then
    start_socat 8080 "$GATEWAY_UPSTREAM" 8080
    start_socat 8081 "$GATEWAY_UPSTREAM" 8081
  fi

  case "${NEMOCLAW_PROVIDER:-}" in
    ollama | install-ollama | custom)
      log "waiting for Ollama"
      for i in $(seq 1 45); do
        if OLLAMA_UPSTREAM="$(pick_upstream 11434 /api/version http_ok)"; then
          break
        fi
        if http_ok "http://ollama:11434/api/version"; then
          OLLAMA_UPSTREAM=ollama
          break
        fi
        OLLAMA_UPSTREAM=""
        sleep 2
      done
      [[ -n "$OLLAMA_UPSTREAM" ]] || die "Ollama is not reachable from this container"
      if [[ "$OLLAMA_UPSTREAM" != "127.0.0.1" ]]; then
        start_socat 11434 "$OLLAMA_UPSTREAM" 11434
      fi
      ;;
  esac
}

register_gateway() {
  local out
  if out="$(openshell gateway add http://127.0.0.1:8080 --name openshell-docker 2>&1)"; then
    log "registered compose gateway as openshell-docker"
    return 0
  fi
  case "$out" in
    *"already exists"*|*"already registered"*)
      log "compose gateway already registered"
      return 0
      ;;
  esac
  printf '%s\n' "$out" >&2
  die "openshell gateway add failed"
}

cli_installed() {
  local bin path
  bin="$(cli_name)"
  path="$(command -v "$bin" 2>/dev/null || true)"
  [[ -n "$path" && -x "$path" ]] || return 1
  "$path" --version >/dev/null 2>&1
}

repair_cli_shims() {
  local path
  if cli_installed; then
    return 0
  fi
  for path in \
    /root/.local/bin/nemohermes \
    /root/.local/bin/nemoclaw \
    /root/.local/bin/nemo-deepagents \
    /root/.local/bin/nemoclaw-acp
  do
    if [[ -e "$path" ]]; then
      log "removing leftover ${path}"
      rm -f "$path"
    fi
  done
  hash -r >/dev/null 2>&1 || true
}

ensure_cli() {
  local stamp="${HOME}/.nemoclaw-compose-ref"
  repair_cli_shims
  if [[ "$ACTION" != "upgrade" ]] && cli_installed; then
    local installed_ref=""
    if [[ -f "$stamp" ]]; then
      installed_ref="$(tr -d '[:space:]' <"$stamp")"
    fi
    if [[ -z "$installed_ref" || "$installed_ref" == "${NEMOCLAW_INSTALL_REF:-}" ]]; then
      printf '%s\n' "${NEMOCLAW_INSTALL_REF:-}" >"$stamp"
      return 0
    fi
  fi
  [[ -n "${NEMOCLAW_INSTALL_REF:-}" ]] || die "NEMOCLAW_INSTALL_REF is required"
  local install_url="https://raw.githubusercontent.com/NVIDIA/NemoClaw/${NEMOCLAW_INSTALL_REF}/install.sh"
  log "installing NemoClaw CLI from ${NEMOCLAW_INSTALL_REF}"
  curl -fsSL "$install_url" | \
    NEMOCLAW_INSTALL_REF="$NEMOCLAW_INSTALL_REF" \
    NEMOCLAW_NON_INTERACTIVE=1 \
    NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 \
    NEMOCLAW_DEFER_OPENSHELL_INSTALL=1 \
    NEMOCLAW_OPENSHELL_BIN="$NEMOCLAW_OPENSHELL_BIN" \
    bash
  mkdir -p "$HOME"
  printf '%s\n' "$NEMOCLAW_INSTALL_REF" >"${HOME}/.nemoclaw-compose-ref"
}

sandbox_ok() {
  [[ -n "${NEMOCLAW_SANDBOX_NAME:-}" ]] || return 1
  cli_installed || return 1
  cli "$NEMOCLAW_SANDBOX_NAME" status >/dev/null 2>&1
}

run_onboard() {
  log "onboarding sandbox ${NEMOCLAW_SANDBOX_NAME}"
  if cli onboard --non-interactive --yes-i-accept-third-party-software --yes --resume; then
    return 0
  fi
  log "resume failed; running onboard without --resume"
  cli onboard --non-interactive --yes-i-accept-third-party-software --yes
}

run_upgrade() {
  log "upgrading sandboxes"
  cli upgrade-sandboxes --check || true
}

verify() {
  [[ -n "${NEMOCLAW_SANDBOX_NAME:-}" ]] || die "NEMOCLAW_SANDBOX_NAME is required"
  log "verifying sandbox ${NEMOCLAW_SANDBOX_NAME}"
  cli "$NEMOCLAW_SANDBOX_NAME" status
  cli "$NEMOCLAW_SANDBOX_NAME" connect --probe-only
  log "sandbox ${NEMOCLAW_SANDBOX_NAME} is healthy"
}

serve() {
  if [[ -n "${NEMOCLAW_SANDBOX_NAME:-}" ]] && cli_installed; then
    cli "$NEMOCLAW_SANDBOX_NAME" start >/dev/null 2>&1 || true
  fi
  log "controller ready; keeping inference proxy and CLI alive"
  exec sleep infinity
}

prepare_loopback
ensure_cli
register_gateway

case "$ACTION" in
  onboard)
    run_onboard
    verify
    serve
    ;;
  upgrade)
    run_onboard
    run_upgrade
    verify
    serve
    ;;
  status)
    verify
    ;;
  serve)
    if ! sandbox_ok; then
      run_onboard
      verify
    fi
    serve
    ;;
  *)
    die "unknown action '${ACTION}' (expected onboard, upgrade, status, or serve)"
    ;;
esac
