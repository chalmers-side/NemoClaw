# Shared helpers for deploy.sh and status.sh.
# Sourced only; do not execute this file.

# Never enable xtrace. Secrets must not appear in logs or process listings
# reconstructed from shell traces.
set +x
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT}/compose/docker-compose.yml"

KNOWN_SECRET_VARS=(
  NVIDIA_INFERENCE_API_KEY
  NVIDIA_API_KEY
  OPENAI_API_KEY
  ANTHROPIC_API_KEY
  OPENROUTER_API_KEY
  GEMINI_API_KEY
  COMPATIBLE_API_KEY
  COMPATIBLE_ANTHROPIC_API_KEY
  TAVILY_API_KEY
  BRAVE_API_KEY
  TELEGRAM_BOT_TOKEN
  SLACK_BOT_TOKEN
  SLACK_APP_TOKEN
  DISCORD_BOT_TOKEN
  HF_TOKEN
  HUGGING_FACE_HUB_TOKEN
  GITHUB_TOKEN
  NEMOCLAW_PROVIDER_KEY
)

die() {
  printf 'error: %s\n' "$*" >&2
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    local msg="${*//$'\n'/ }"
    msg="${msg//%/%%}"
    printf '::error::%s\n' "$msg"
  fi
  exit 1
}

unset_secrets() {
  # shellcheck disable=SC2086
  unset "${KNOWN_SECRET_VARS[@]}" 2>/dev/null || true
}

require_target() {
  local target="${1:-}"
  [[ -n "$target" ]] || die "usage: $0 <target> [action]"
  [[ "$target" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid target name: $target"
  TARGET="$target"
  CONFIG_FILE="${ROOT}/personal_config/${target}/config.env"
  [[ -f "$CONFIG_FILE" ]] || die "missing ${CONFIG_FILE}"
  SECRETS_FILE="${SECRETS_FILE:-${ROOT}/personal_config/${target}/secrets.env}"
}

assert_not_actions_worktree() {
  [[ -n "${GITHUB_ACTIONS:-}" ]] || return 0
  case "$ROOT" in
    */actions-runner/_work/*)
      die "Actions must run from /opt/app/NemoClaw, not ${ROOT}"
      ;;
  esac
}

deploy_state_dir() {
  printf '%s\n' "${HOME}/.nemoclaw/deploy-state/${TARGET:?}"
}

current_deploy_sha() {
  if [[ -n "${GITHUB_SHA:-}" ]]; then
    printf '%s\n' "$GITHUB_SHA"
    return 0
  fi
  git -C "$ROOT" rev-parse HEAD
}

write_stage_marker() {
  local stage="${1:?}" dir sha
  dir="$(deploy_state_dir)"
  sha="$(current_deploy_sha)"
  mkdir -p "$dir"
  chmod 700 "${HOME}/.nemoclaw" "$(dirname "$dir")" "$dir" 2>/dev/null || true
  printf '%s\n' "$sha" >"${dir}/${stage}"
}

# Disabled LaunchAgents fail bootstrap with "Input/output error" (5). Enable first.
launchctl_bootstrap_gui() {
  local label="${1:?}" plist="${2:?}" uid attempt
  uid="$(id -u)"
  [[ -f "$plist" ]] || die "missing LaunchAgent ${plist}"
  launchctl enable "gui/${uid}/${label}" >/dev/null 2>&1 || true
  launchctl bootout "gui/${uid}/${label}" >/dev/null 2>&1 || true
  for attempt in 1 2 3 4 5; do
    if launchctl bootstrap "gui/${uid}" "$plist"; then
      launchctl enable "gui/${uid}/${label}" >/dev/null 2>&1 || true
      printf 'launchctl bootstrap gui/%s/%s ok\n' "$uid" "$label"
      return 0
    fi
    printf 'launchctl bootstrap %s attempt %s failed; retry\n' "$label" "$attempt"
    sleep $((attempt))
    launchctl enable "gui/${uid}/${label}" >/dev/null 2>&1 || true
    launchctl bootout "gui/${uid}/${label}" >/dev/null 2>&1 || true
  done
  die "failed to bootstrap ${label}. Check launchctl print-disabled gui/${uid} and ${HOME}/Library/Logs."
}

deploy_lock_file() {
  printf '%s\n' "$(deploy_state_dir)/deploy.lock"
}

DEPLOY_LOCK_PYTHON_PID=""
NEMOCLAW_DEPLOY_LOCK_HELD="${NEMOCLAW_DEPLOY_LOCK_HELD:-}"

release_deploy_lock() {
  if [[ -n "${DEPLOY_LOCK_PYTHON_PID:-}" ]]; then
    kill "$DEPLOY_LOCK_PYTHON_PID" 2>/dev/null || true
    wait "$DEPLOY_LOCK_PYTHON_PID" 2>/dev/null || true
    DEPLOY_LOCK_PYTHON_PID=""
  fi
  NEMOCLAW_DEPLOY_LOCK_HELD=""
}

# Hold an exclusive lock for TARGET until this shell exits.
# Wait up to 900s. A dead holder is released by fcntl when that process exits.
acquire_deploy_lock() {
  local lockfile statusfile status wait_s i
  [[ -z "${NEMOCLAW_DEPLOY_LOCK_HELD:-}" ]] || return 0
  [[ -n "${TARGET:-}" ]] || die "acquire_deploy_lock requires TARGET"
  wait_s="${NEMOCLAW_DEPLOY_LOCK_WAIT:-900}"
  lockfile="$(deploy_lock_file)"
  mkdir -p "$(deploy_state_dir)"
  chmod 700 "${HOME}/.nemoclaw" "$(dirname "$(deploy_state_dir)")" "$(deploy_state_dir)" 2>/dev/null || true
  statusfile="$(mktemp "${TMPDIR:-/tmp}/nemoclaw-lockstatus.XXXXXX")"
  python3 -c '
import errno, fcntl, os, sys, time
path, timeout, statusfile, pid = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
os.makedirs(os.path.dirname(path), exist_ok=True)
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
deadline = time.time() + timeout
locked = False
try:
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            locked = True
            break
        except OSError as exc:
            if exc.errno not in (errno.EACCES, errno.EAGAIN):
                raise
            if time.time() >= deadline:
                with open(statusfile, "w") as out:
                    out.write("TIMEOUT\n")
                sys.exit(1)
            time.sleep(1)
    os.lseek(fd, 0, os.SEEK_SET)
    os.ftruncate(fd, 0)
    os.write(fd, (pid + "\n").encode())
    os.fsync(fd)
    with open(statusfile, "w") as out:
        out.write("LOCKED\n")
    while True:
        time.sleep(3600)
finally:
    if locked:
        fcntl.flock(fd, fcntl.LOCK_UN)
    os.close(fd)
' "$lockfile" "$wait_s" "$statusfile" "$$" >/dev/null 2>&1 &
  DEPLOY_LOCK_PYTHON_PID=$!
  status=""
  i=0
  while [[ "$i" -le "$wait_s" ]]; do
    if [[ -s "$statusfile" ]]; then
      status="$(tr -d '[:space:]' <"$statusfile")"
      break
    fi
    if ! kill -0 "$DEPLOY_LOCK_PYTHON_PID" 2>/dev/null; then
      wait "$DEPLOY_LOCK_PYTHON_PID" 2>/dev/null || true
      status="$(tr -d '[:space:]' <"$statusfile" 2>/dev/null || true)"
      break
    fi
    sleep 1
    i=$((i + 1))
  done
  rm -f "$statusfile"
  if [[ "$status" != "LOCKED" ]]; then
    kill "$DEPLOY_LOCK_PYTHON_PID" 2>/dev/null || true
    wait "$DEPLOY_LOCK_PYTHON_PID" 2>/dev/null || true
    DEPLOY_LOCK_PYTHON_PID=""
    die "another deploy holds ${lockfile}. Wait for it to finish, or run status after it exits."
  fi
  NEMOCLAW_DEPLOY_LOCK_HELD=1
  export NEMOCLAW_DEPLOY_LOCK_HELD
  printf 'deploy lock acquired for %s (%s)\n' "$TARGET" "$lockfile"
}

run_with_timeout() {
  local seconds="${1:-}"
  shift
  [[ -n "$seconds" && -n "${1:-}" ]] || die "usage: run_with_timeout <seconds> <command> [args...]"
  python3 - "$seconds" "$@" <<'PY'
import os
import signal
import subprocess
import sys

seconds = int(sys.argv[1])
cmd = sys.argv[2:]
label = " ".join(cmd)
try:
    proc = subprocess.Popen(cmd, preexec_fn=os.setsid)
except OSError as exc:
    sys.stderr.write("error: could not start %s: %s\n" % (label, exc))
    sys.exit(127)
try:
    rc = proc.wait(timeout=seconds)
except subprocess.TimeoutExpired:
    sys.stderr.write("error: timed out after %ss: %s\n" % (seconds, label))
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except OSError:
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        proc.wait()
    sys.exit(124)
sys.exit(rc if rc is not None else 1)
PY
}

sandbox_container_id() {
  local cid
  cid="$(docker ps -aq --filter "name=openshell-default--${NEMOCLAW_SANDBOX_NAME}" 2>/dev/null || true)"
  cid="${cid%%$'\n'*}"
  printf '%s\n' "$cid"
}

sandbox_container_running() {
  docker ps --filter "name=openshell-default--${NEMOCLAW_SANDBOX_NAME}" --format '{{.ID}}' 2>/dev/null | grep -q .
}

# True when Docker or nemohermes already knows this sandbox. Do not create another.
sandbox_exists() {
  local cid state
  cid="$(sandbox_container_id)"
  [[ -n "$cid" ]] && return 0
  state="$(classify_host_sandbox)"
  [[ "$state" != "absent" ]]
}

ollama_http_ok() {
  curl -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1
}

health_ollama() {
  printf 'health ollama: checking 127.0.0.1:11434\n'
  if ollama_http_ok; then
    printf 'health ollama: ok\n'
    return 0
  fi
  die "health ollama: 127.0.0.1:11434 did not answer. Run: bash ./scripts/deploy.sh ${TARGET} ollama"
}

gateway_http_ok() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8080/ || true)"
  case "$code" in
    2* | 3* | 4*) return 0 ;;
  esac
  return 1
}

health_gateway() {
  printf 'health gateway: checking OpenShell on 127.0.0.1:8080\n'
  if ! gateway_http_ok; then
    die "health gateway: 127.0.0.1:8080 did not answer (2xx-4xx). Run: bash ./scripts/deploy.sh ${TARGET} nemoclaw"
  fi
  if ! openshell_is_connected; then
    die "health gateway: openshell status is not Connected. Run: bash ./scripts/deploy.sh ${TARGET} nemoclaw"
  fi
  printf 'health gateway: ok (Connected)\n'
}

health_sandbox() {
  local state cid
  printf 'health sandbox: checking %s\n' "$NEMOCLAW_SANDBOX_NAME"
  cid="$(sandbox_container_id)"
  state="$(classify_host_sandbox)"
  printf 'health sandbox: state=%s container=%s\n' "$state" "${cid:-none}"
  case "$state" in
    ready)
      if ! sandbox_container_running; then
        die "health sandbox: ${NEMOCLAW_SANDBOX_NAME} is Ready in CLI but the container is not running. Run: bash ./scripts/recover-sandbox.sh ${TARGET}"
      fi
      printf 'health sandbox: ok (Ready)\n'
      ;;
    error)
      die "health sandbox: ${NEMOCLAW_SANDBOX_NAME} is Error. Do not onboard or recreate. Run: bash ./scripts/recover-sandbox.sh ${TARGET}"
      ;;
    absent)
      die "health sandbox: ${NEMOCLAW_SANDBOX_NAME} is not installed. Run First deploy: bash ./scripts/deploy.sh ${TARGET} onboard"
      ;;
    *)
      if [[ -n "$cid" ]]; then
        die "health sandbox: ${NEMOCLAW_SANDBOX_NAME} exists (container ${cid}) but state=${state}. Do not onboard. Run: bash ./scripts/recover-sandbox.sh ${TARGET}"
      fi
      die "health sandbox: ${NEMOCLAW_SANDBOX_NAME} state=${state}. Inspect it; do not onboard --resume. Run: bash ./scripts/recover-sandbox.sh ${TARGET}"
      ;;
  esac
}

sync_sandbox_config() {
  printf 'syncing sandbox config for %s (no create)\n' "$NEMOCLAW_SANDBOX_NAME"
  if ! sandbox_container_running; then
    printf 'sandbox container is not running; skip config sync\n'
    return 0
  fi
  repair_sandbox_openshell_hosts
  ensure_hermes_inference_placeholder || true
  ensure_hermes_discord_platform || true
}

run_health_checks() {
  health_ollama
  health_gateway
  health_sandbox
}

load_config() {
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a

  OS="${OS:-}"
  NEMOCLAW_AGENT="${NEMOCLAW_AGENT:-openclaw}"
  NEMOCLAW_PROVIDER="${NEMOCLAW_PROVIDER:-}"
  NEMOCLAW_MODEL="${NEMOCLAW_MODEL:-}"
  NEMOCLAW_YES="${NEMOCLAW_YES:-}"
  NEMOCLAW_SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-}"
  NEMOCLAW_POLICY_TIER="${NEMOCLAW_POLICY_TIER:-balanced}"
  NEMOCLAW_WEB_SEARCH_PROVIDER="${NEMOCLAW_WEB_SEARCH_PROVIDER:-none}"
  NEMOCLAW_IGNORE_RUNTIME_RESOURCES="${NEMOCLAW_IGNORE_RUNTIME_RESOURCES:-}"
  DISCORD_SERVER_ID="${DISCORD_SERVER_ID:-}"
  DISCORD_REQUIRE_MENTION="${DISCORD_REQUIRE_MENTION:-}"
  DISCORD_USER_ID="${DISCORD_USER_ID:-}"

  if [[ -z "${NEMOCLAW_INSTALL_REF:-}" ]]; then
    NEMOCLAW_INSTALL_REF="$(tr -d '[:space:]' <"${ROOT}/NEMOCLAW_VERSION")"
  fi
  if [[ -z "${OPENSHELL_VERSION:-}" ]]; then
    OPENSHELL_VERSION="$(tr -d '[:space:]' <"${ROOT}/OPENSHELL_VERSION")"
  fi
  OPENSHELL_IMAGE_TAG="${OPENSHELL_IMAGE_TAG:-${OPENSHELL_VERSION#v}}"

  [[ "$OS" == "linux" || "$OS" == "macos" ]] || die "OS must be linux or macos in ${CONFIG_FILE}"
  case "$NEMOCLAW_AGENT" in
    openclaw | hermes | langchain-deepagents-code) ;;
    *) die "NEMOCLAW_AGENT must be openclaw, hermes, or langchain-deepagents-code" ;;
  esac
  [[ -n "$NEMOCLAW_PROVIDER" ]] || die "NEMOCLAW_PROVIDER is required in ${CONFIG_FILE}"
  [[ -n "$NEMOCLAW_SANDBOX_NAME" ]] || die "NEMOCLAW_SANDBOX_NAME is required in ${CONFIG_FILE}"
  [[ "$NEMOCLAW_SANDBOX_NAME" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]] ||
    die "NEMOCLAW_SANDBOX_NAME must be lowercase, start with a letter, and use only letters, digits, and hyphens"
  [[ "$NEMOCLAW_INSTALL_REF" =~ ^[0-9a-f]{40}$ ]] ||
    die "NEMOCLAW_INSTALL_REF must be a 40-character commit SHA (got: ${NEMOCLAW_INSTALL_REF})"
}

assert_host_os() {
  local uname_s
  uname_s="$(uname -s)"
  case "$OS" in
    linux)
      [[ "$uname_s" == "Linux" ]] || die "config OS=linux but this host is ${uname_s}"
      ;;
    macos)
      [[ "$uname_s" == "Darwin" ]] || die "config OS=macos but this host is ${uname_s}"
      ;;
  esac
}

load_secrets() {
  local cred
  cred="$(provider_credential_var)"
  if [[ ! -f "$SECRETS_FILE" ]]; then
    if [[ -n "${GITHUB_ACTIONS:-}" && -f "${ROOT}/personal_config/secrets.env.example" ]]; then
      mkdir -p "$(dirname "$SECRETS_FILE")"
      chmod 700 "${HOME}/.nemoclaw/runner-secrets" "$(dirname "$SECRETS_FILE")" 2>/dev/null || true
      cp "${ROOT}/personal_config/secrets.env.example" "$SECRETS_FILE"
      chmod 600 "$SECRETS_FILE"
      die "wrote a placeholder at ${SECRETS_FILE}. Fill the keys for ${TARGET}, then rerun."
    fi
    if [[ -n "$cred" ]] || [[ -n "${DISCORD_SERVER_ID:-}" ]] || [[ "${NEMOCLAW_WEB_SEARCH_PROVIDER}" == "tavily" || "${NEMOCLAW_WEB_SEARCH_PROVIDER}" == "brave" ]]; then
      die "missing ${SECRETS_FILE} (mode 600). Fill that file on the machine; do not put secrets in actions-runner/_work"
    fi
    printf 'no secrets file at %s (ok when this config needs no keys)\n' "$SECRETS_FILE"
    return 0
  fi
  local mode
  mode="$(stat -f '%OLp' "$SECRETS_FILE" 2>/dev/null || stat -c '%a' "$SECRETS_FILE")"
  if [[ "$mode" != "600" && "$mode" != "400" ]]; then
    die "secrets file ${SECRETS_FILE} must be mode 600 or 400 (got ${mode})"
  fi
  set -a
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  set +a
}

provider_credential_var() {
  case "$NEMOCLAW_PROVIDER" in
    build | cloud | routed) printf '%s\n' NVIDIA_INFERENCE_API_KEY ;;
    openai) printf '%s\n' OPENAI_API_KEY ;;
    anthropic) printf '%s\n' ANTHROPIC_API_KEY ;;
    openrouter | open-router | openrouterai) printf '%s\n' OPENROUTER_API_KEY ;;
    gemini) printf '%s\n' GEMINI_API_KEY ;;
    custom) printf '%s\n' COMPATIBLE_API_KEY ;;
    anthropicCompatible | anthropiccompatible) printf '%s\n' COMPATIBLE_ANTHROPIC_API_KEY ;;
    ollama | vllm | nim-local | install-vllm | install-ollama | install-windows-ollama | start-windows-ollama | hermes-provider | hermesProvider | hermesprovider) ;;
    *) die "unsupported NEMOCLAW_PROVIDER=${NEMOCLAW_PROVIDER}" ;;
  esac
}

secret_is_set() {
  case "$1" in
    NVIDIA_INFERENCE_API_KEY) [[ -n "${NVIDIA_INFERENCE_API_KEY:-}" ]] ;;
    NVIDIA_API_KEY) [[ -n "${NVIDIA_API_KEY:-}" ]] ;;
    OPENAI_API_KEY) [[ -n "${OPENAI_API_KEY:-}" ]] ;;
    ANTHROPIC_API_KEY) [[ -n "${ANTHROPIC_API_KEY:-}" ]] ;;
    OPENROUTER_API_KEY) [[ -n "${OPENROUTER_API_KEY:-}" ]] ;;
    GEMINI_API_KEY) [[ -n "${GEMINI_API_KEY:-}" ]] ;;
    COMPATIBLE_API_KEY) [[ -n "${COMPATIBLE_API_KEY:-}" ]] ;;
    COMPATIBLE_ANTHROPIC_API_KEY) [[ -n "${COMPATIBLE_ANTHROPIC_API_KEY:-}" ]] ;;
    TAVILY_API_KEY) [[ -n "${TAVILY_API_KEY:-}" ]] ;;
    BRAVE_API_KEY) [[ -n "${BRAVE_API_KEY:-}" ]] ;;
    TELEGRAM_BOT_TOKEN) [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] ;;
    SLACK_BOT_TOKEN) [[ -n "${SLACK_BOT_TOKEN:-}" ]] ;;
    SLACK_APP_TOKEN) [[ -n "${SLACK_APP_TOKEN:-}" ]] ;;
    DISCORD_BOT_TOKEN) [[ -n "${DISCORD_BOT_TOKEN:-}" ]] ;;
    HF_TOKEN) [[ -n "${HF_TOKEN:-}" ]] ;;
    HUGGING_FACE_HUB_TOKEN) [[ -n "${HUGGING_FACE_HUB_TOKEN:-}" ]] ;;
    GITHUB_TOKEN) [[ -n "${GITHUB_TOKEN:-}" ]] ;;
    NEMOCLAW_PROVIDER_KEY) [[ -n "${NEMOCLAW_PROVIDER_KEY:-}" ]] ;;
    *) die "internal error: unknown secret ${1}" ;;
  esac
}

require_secret_var() {
  secret_is_set "$1" || die "$1 is required in ${SECRETS_FILE} for this config"
}

validate_secrets() {
  local cred
  cred="$(provider_credential_var)"
  if [[ -n "$cred" ]]; then
    require_secret_var "$cred"
  fi
  case "${NEMOCLAW_WEB_SEARCH_PROVIDER}" in
    none | "") ;;
    tavily) require_secret_var TAVILY_API_KEY ;;
    brave) require_secret_var BRAVE_API_KEY ;;
    *) die "unsupported NEMOCLAW_WEB_SEARCH_PROVIDER=${NEMOCLAW_WEB_SEARCH_PROVIDER}" ;;
  esac
  if [[ -n "${DISCORD_SERVER_ID:-}" ]]; then
    [[ "$DISCORD_SERVER_ID" =~ ^[0-9]{17,20}$ ]] ||
      die "DISCORD_SERVER_ID in ${CONFIG_FILE} must be a Discord snowflake (17-20 digits)"
    require_secret_var DISCORD_BOT_TOKEN
  fi
}

# OpenShell's L7 proxy resolves host.openshell.internal on the gateway host
# and checks allowed_ips (RFC1918). Docker Desktop extra_hosts only exist
# inside sandbox containers, so a native macOS gateway gets ssrf_denied
# unless this name resolves locally to a loopback RFC1918 alias.
MACOS_OPENSHELL_BRIDGE_IP="${MACOS_OPENSHELL_BRIDGE_IP:-10.255.255.254}"

ensure_macos_host_openshell_internal() {
  [[ "$(uname -s)" == "Darwin" ]] || return 0
  local ip="$MACOS_OPENSHELL_BRIDGE_IP"
  local name="host.openshell.internal"
  if ! ifconfig lo0 2>/dev/null | grep -q "inet ${ip} "; then
    if ! sudo -n ifconfig lo0 alias "$ip" netmask 255.255.255.255 2>/dev/null; then
      die "macOS needs loopback alias ${ip} for ${name}. Run: sudo ifconfig lo0 alias ${ip} netmask 255.255.255.255"
    fi
  fi
  if ! grep -Eq "^${ip}[[:space:]]+${name}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
    if ! printf '%s\t%s\t# nemoclaw-host-openshell-internal\n' "$ip" "$name" | sudo -n tee -a /etc/hosts >/dev/null; then
      die "macOS needs /etc/hosts entry '${ip} ${name}'. Add it, then rerun."
    fi
  fi
  dscacheutil -flushcache >/dev/null 2>&1 || true
}

# One-shot boot restore. Without a cached sudo credential this does not
# write /Library or /etc; the alias then lasts only until reboot.
install_macos_bridge_boot_daemon() {
  [[ "$(uname -s)" == "Darwin" ]] || return 0
  local label="com.nemoclaw.openshell-bridge"
  local plist="/Library/LaunchDaemons/${label}.plist"
  local script="${ROOT}/scripts/macos-openshell-bridge.sh"
  [[ -f "$script" ]] || die "missing ${script}"
  chmod 755 "$script"
  if ! sudo -n true >/dev/null 2>&1; then
    printf 'note: sudo -n unavailable; loopback alias %s will not be restored at boot\n' \
      "$MACOS_OPENSHELL_BRIDGE_IP"
    return 0
  fi
  sudo -n tee "$plist" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${script}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
EOF
  sudo -n chown root:wheel "$plist"
  sudo -n chmod 644 "$plist"
  sudo -n launchctl bootout "system/${label}" >/dev/null 2>&1 || true
  sudo -n launchctl bootstrap system "$plist" || die "failed to bootstrap ${label}"
}

ensure_homebrew_openshell_gateway() {
  local uid i code gw bin_dir work
  uid="$(id -u)"
  bin_dir="${HOME}/.nemoclaw/openshell/bin"
  if [[ -x /opt/homebrew/bin/openshell-gateway ]]; then
    gw=/opt/homebrew/bin/openshell-gateway
  else
    gw="${bin_dir}/openshell-gateway"
  fi
  if [[ ! -x "$gw" || ! -x "$(dirname "$gw")/openshell" ]]; then
    # github.com/nvidia/homebrew-openshell answers 401 without a login, so brew tap
    # cannot run from the Actions agent. The release tarballs are public.
    mkdir -p "$bin_dir"
    work="$(mktemp -d)"
    curl -fsSL -L -o "${work}/openshell.tar.gz" \
      "https://github.com/NVIDIA/OpenShell/releases/download/v0.0.116/openshell-aarch64-apple-darwin.tar.gz" \
      || die "failed to download OpenShell CLI"
    curl -fsSL -L -o "${work}/gateway.tar.gz" \
      "https://github.com/NVIDIA/OpenShell/releases/download/v0.0.116/openshell-gateway-aarch64-apple-darwin.tar.gz" \
      || die "failed to download OpenShell gateway"
    printf '%s  %s\n' "e582f2374053bebac8e6aaeb4a369931b7d4bb97bd55055e2c02e85502627e22" "${work}/openshell.tar.gz" | shasum -a 256 -c - \
      || die "OpenShell CLI checksum mismatch"
    printf '%s  %s\n' "f192d3d737c125264e13ef73458541df2ca6a9eb2fa599736a7f2587d5d2ce8d" "${work}/gateway.tar.gz" | shasum -a 256 -c - \
      || die "OpenShell gateway checksum mismatch"
    tar -xzf "${work}/openshell.tar.gz" -C "$bin_dir"
    tar -xzf "${work}/gateway.tar.gz" -C "$bin_dir"
    chmod 755 "${bin_dir}/openshell" "${bin_dir}/openshell-gateway"
    rm -rf "$work"
    gw="${bin_dir}/openshell-gateway"
  fi
  export PATH="$(dirname "$gw"):${PATH}"
  # Recorded mTLS gateway is the path onboard and Discord already use.
  # Do not KeepAlive a --disable-tls listener on 8080 (Actions or local).
  if [[ -d "${HOME}/.local/state/nemoclaw/openshell-docker-gateway/tls" ]]; then
    stop_actions_openshell_launchagent
    launchctl bootout "gui/${uid}/com.nemoclaw.openshell-gateway" >/dev/null 2>&1 || true
    ensure_recorded_tls_gateway "$gw"
    return 0
  fi
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    stop_actions_openshell_launchagent
    ensure_recorded_tls_gateway "$gw"
    return 0
  fi
  local plist="${HOME}/Library/LaunchAgents/com.nemoclaw.openshell-gateway.plist"
  mkdir -p "${HOME}/Library/LaunchAgents" "${HOME}/Library/Logs"
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.nemoclaw.openshell-gateway</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:${HOME}/.docker/bin:/usr/bin:/bin</string>
  </dict>
  <key>ProgramArguments</key>
  <array>
    <string>${gw}</string>
    <string>--bind-address</string>
    <string>127.0.0.1</string>
    <string>--port</string>
    <string>8080</string>
    <string>--disable-tls</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${HOME}/Library/Logs/nemoclaw-openshell-gateway.log</string>
  <key>StandardErrorPath</key>
  <string>${HOME}/Library/Logs/nemoclaw-openshell-gateway.log</string>
</dict>
</plist>
EOF
  launchctl_bootstrap_gui "com.nemoclaw.openshell-gateway" "$plist"
  for i in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8080/ || true)"
    case "$code" in
      2* | 3* | 4*) return 0 ;;
    esac
    sleep 1
  done
  die "OpenShell gateway did not answer on 127.0.0.1:8080. $(tail -n 30 "${HOME}/Library/Logs/nemoclaw-openshell-gateway.log" 2>/dev/null || true)"
}

openshell_status_text() {
  run_with_timeout 15 openshell status 2>&1 | sed $'s/\x1b\\[[0-9;]*[[:alpha:]]//g' || true
}

openshell_is_connected() {
  local out
  command -v openshell >/dev/null 2>&1 || return 1
  out="$(openshell_status_text)"
  printf '%s\n' "$out" | grep -qiE 'status:[[:space:]]*connected|authenticated \(mtls'
}

# Recorded docker-driver mTLS gateway. Empty args; do not pass --disable-tls.
ensure_recorded_tls_gateway() {
  local gw="${1:-}" i log gw_state cfg
  if [[ -z "$gw" ]]; then
    if [[ -x /opt/homebrew/bin/openshell-gateway ]]; then
      gw=/opt/homebrew/bin/openshell-gateway
    else
      gw="${HOME}/.nemoclaw/openshell/bin/openshell-gateway"
    fi
  fi
  [[ -x "$gw" ]] || die "openshell-gateway is not executable"
  export PATH="$(dirname "$gw"):${PATH}"
  gw_state="${HOME}/.local/state/nemoclaw/openshell-docker-gateway"
  if [[ ! -d "${gw_state}/tls" ]]; then
    die "missing ${gw_state}/tls. On the Mac mini the recorded mTLS gateway must already exist. Start openshell-gateway once with OPENSHELL_LOCAL_TLS_DIR, OPENSHELL_GATEWAY_CONFIG, and OPENSHELL_DB_URL under that directory. Do not pass --disable-tls."
  fi
  export OPENSHELL_LOCAL_TLS_DIR="${gw_state}/tls"
  cfg=""
  if [[ -f "${gw_state}/openshell-gateway.toml" ]]; then
    cfg="${gw_state}/openshell-gateway.toml"
  elif [[ -f "${gw_state}/gateway.toml" ]]; then
    cfg="${gw_state}/gateway.toml"
  fi
  [[ -n "$cfg" ]] && export OPENSHELL_GATEWAY_CONFIG="$cfg"
  if [[ -f "${gw_state}/openshell.db" ]]; then
    export OPENSHELL_DB_URL="sqlite:${gw_state}/openshell.db"
  fi
  export OPENSHELL_SERVER_PORT="${OPENSHELL_SERVER_PORT:-8080}"
  export OPENSHELL_BIND_ADDRESS="${OPENSHELL_BIND_ADDRESS:-127.0.0.1}"
  openshell gateway select nemoclaw >/dev/null 2>&1 || true
  printf 'openshell status:\n'
  openshell_status_text || true
  if openshell_is_connected; then
    printf 'recorded OpenShell gateway is already Connected\n'
    return 0
  fi
  printf '8080 listeners:\n'
  lsof -nP -iTCP:8080 -sTCP:LISTEN 2>/dev/null || true
  local pid args occupied=0
  for pid in $(listener_pids 8080); do
    args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    case "$args" in
      *docker-proxy*|*com.docker*)
        die "127.0.0.1:8080 is a Docker-published port. Stop that container. Do not kill Docker.app."
        ;;
      *openshell-gateway*--disable-tls*)
        printf 'stopping plaintext openshell-gateway on 8080 so TLS can bind\n'
        kill -TERM "$pid" || true
        ;;
      *openshell-gateway*)
        occupied=1
        ;;
    esac
  done
  sleep 2
  openshell gateway select nemoclaw >/dev/null 2>&1 || true
  if openshell_is_connected; then
    printf 'recorded OpenShell gateway is Connected\n'
    return 0
  fi
  if [[ "$occupied" -eq 1 ]]; then
    for i in $(seq 1 15); do
      if openshell_is_connected; then
        printf 'recorded OpenShell gateway is Connected\n'
        return 0
      fi
      sleep 1
    done
    printf 'openshell-gateway is on 8080 but status is not Connected; restarting the TLS listener\n'
    {
      printf '\n--- openshell gateway list ---\n'
      openshell gateway list || true
      printf '\n--- openshell status ---\n'
      openshell status || true
    } || true
    for pid in $(listener_pids 8080); do
      args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
      case "$args" in
        *openshell-gateway*)
          kill -TERM "$pid" || true
          ;;
      esac
    done
    sleep 3
  fi
  [[ -n "$cfg" && -n "${OPENSHELL_DB_URL:-}" ]] || die "recorded TLS gateway is missing gateway.toml or openshell.db"
  log="${HOME}/Library/Logs/nemoclaw-openshell-gateway-tls.log"
  mkdir -p "${HOME}/Library/Logs" "${HOME}/Library/LaunchAgents"
  : >"$log"
  printf 'starting recorded TLS openshell-gateway on 127.0.0.1:8080\n'
  local uid plist
  uid="$(id -u)"
  plist="${HOME}/Library/LaunchAgents/com.nemoclaw.openshell-gateway.plist"
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.nemoclaw.openshell-gateway</string>
  <key>ProgramArguments</key>
  <array>
    <string>${gw}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OPENSHELL_LOCAL_TLS_DIR</key>
    <string>${gw_state}/tls</string>
    <key>OPENSHELL_GATEWAY_CONFIG</key>
    <string>${cfg}</string>
    <key>OPENSHELL_DB_URL</key>
    <string>${OPENSHELL_DB_URL}</string>
    <key>OPENSHELL_SERVER_PORT</key>
    <string>8080</string>
    <key>OPENSHELL_BIND_ADDRESS</key>
    <string>127.0.0.1</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:${HOME}/.docker/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${log}</string>
  <key>StandardErrorPath</key>
  <string>${log}</string>
</dict>
</plist>
EOF
  launchctl_bootstrap_gui "com.nemoclaw.openshell-gateway" "$plist"
  for i in $(seq 1 45); do
    if openshell_is_connected; then
      printf 'recorded OpenShell gateway is Connected\n'
      return 0
    fi
    sleep 1
  done
  die "OpenShell gateway did not become Connected. status=$(openshell_status_text | tr '\n' ' '). log=$(tail -n 20 "$log" 2>/dev/null || true)"
}

is_owned_openshell_gateway() {
  local args
  args="$(ps -p "$1" -o args= 2>/dev/null || true)"
  case "$args" in
    *'openshell-gateway[nemoclaw='*) return 0 ;;
  esac
  return 1
}

# NemoClaw onboard only reuses a docker-driver gateway whose argv0 is
# openshell-gateway[nemoclaw=<name>;port=<port>]. A plain nohup listener is
# "other NemoClaw gateway". SIGTERM that leftover so onboard can launch the
# tagged process. Do not kill -9. Do not stop docker-proxy.
release_untagged_openshell_gateway() {
  local pid args i still
  printf '8080 listeners before onboard:\n'
  lsof -nP -iTCP:8080 -sTCP:LISTEN 2>/dev/null || true
  for pid in $(listener_pids 8080); do
    args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    case "$args" in
      *docker-proxy*|*com.docker*)
        die "127.0.0.1:8080 is a Docker-published port. Stop that container. Do not kill Docker.app."
        ;;
      *openshell-gateway*)
        if is_owned_openshell_gateway "$pid"; then
          printf 'keeping NemoClaw-owned openshell-gateway pid %s\n' "$pid"
          continue
        fi
        printf 'stopping untagged openshell-gateway pid %s so onboard can own 8080\n' "$pid"
        kill -TERM "$pid" || true
        ;;
    esac
  done
  for i in $(seq 1 15); do
    still=0
    for pid in $(listener_pids 8080); do
      args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
      case "$args" in
        *docker-proxy*|*com.docker*)
          die "127.0.0.1:8080 is a Docker-published port. Stop that container. Do not kill Docker.app."
          ;;
        *openshell-gateway*)
          if is_owned_openshell_gateway "$pid"; then
            continue
          fi
          still=1
          ;;
      esac
    done
    [[ "$still" -eq 0 ]] && return 0
    sleep 1
  done
  printf '8080 listeners after SIGTERM:\n'
  lsof -nP -iTCP:8080 -sTCP:LISTEN 2>/dev/null || true
  die "untagged openshell-gateway still holds 8080 after SIGTERM. Do not kill -9. Inspect lsof -nP -iTCP:8080 -sTCP:LISTEN."
}

# nemohermes onboard starts its own Docker-driver gateway on 127.0.0.1:8080.
# A KeepAlive LaunchAgent takes the port back after onboard stops it.
stop_actions_openshell_launchagent() {
  local uid
  uid="$(id -u)"
  # Drop a leftover --disable-tls KeepAlive agent. TLS plist is rewritten next.
  if grep -q -- '--disable-tls' "${HOME}/Library/LaunchAgents/com.nemoclaw.openshell-gateway.plist" 2>/dev/null; then
    launchctl bootout "gui/${uid}/com.nemoclaw.openshell-gateway" >/dev/null 2>&1 || true
  fi
}

# Print the current Docker Desktop size. Does not change it.
# 4 CPUs, 6 GiB RAM, 2 GiB swap, and 40 GiB disk are the measurement start.
# Leave RAM alone when the sandbox RSS is already above 6 GiB.
report_docker_desktop_budget() {
  [[ "$(uname -s)" == "Darwin" ]] || return 0
  local info mem cpus cid
  info="$(docker info 2>/dev/null || true)"
  mem="$(printf '%s\n' "$info" | awk -F': ' '/Total Memory/ { print $2; exit }')"
  cpus="$(printf '%s\n' "$info" | awk -F': ' '/^ CPUs/ { print $2; exit }')"
  printf 'Docker Desktop now: CPUs=%s memory=%s\n' "${cpus:-unknown}" "${mem:-unknown}"
  printf 'Measurement start: 4 CPUs, 6 GiB RAM, 2 GiB swap, 40 GiB disk. Do not shrink RAM when sandbox RSS is above 6 GiB.\n'
  cid="$(docker ps --filter "name=openshell-default--${NEMOCLAW_SANDBOX_NAME}" --format '{{.ID}}' | head -1)"
  if [[ -n "$cid" ]]; then
    docker stats --no-stream --format 'sandbox {{.Name}} mem={{.MemUsage}}' "$cid" || true
  fi
}

preflight_host() {
  export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
  command -v docker >/dev/null || die "docker is required"
  if [[ "$OS" == "linux" ]]; then
    docker info >/dev/null || die "docker info failed; the deploying user must be able to talk to Docker"
  elif [[ "$OS" == "macos" ]]; then
    if ! docker info >/dev/null 2>&1; then
      die "Docker Desktop is not running. Open it, wait until docker info works, then rerun."
    fi
    ensure_macos_host_openshell_internal
  fi
  [[ -f "$COMPOSE_FILE" ]] || die "missing ${COMPOSE_FILE}"
}

cli_name() {
  case "${NEMOCLAW_AGENT:-openclaw}" in
    hermes) printf '%s\n' nemohermes ;;
    langchain-deepagents-code) printf '%s\n' nemo-deepagents ;;
    *) printf '%s\n' nemoclaw ;;
  esac
}

compose_project_name() {
  # Docker Compose rejects uppercase in -p / name:.
  printf 'nemoclaw-%s\n' "${TARGET:?}"
}

export_compose_env() {
  export NEMOCLAW_TARGET="${TARGET:?}"
  export NEMOCLAW_ACTION="${NEMOCLAW_ACTION:-serve}"
  export NEMOCLAW_INSTALL_REF
  export OPENSHELL_VERSION
  export OPENSHELL_IMAGE_TAG
  export HOME
  COMPOSE_PROJECT_NAME="$(compose_project_name)"
  export COMPOSE_PROJECT_NAME
}

run_compose() {
  export_compose_env
  mkdir -p "${HOME}/.ollama"
  local project
  project="$(compose_project_name)"
  if docker compose version >/dev/null 2>&1; then
    docker compose -p "$project" -f "$COMPOSE_FILE" --project-directory "${ROOT}/compose" "$@"
  elif command -v docker-compose >/dev/null; then
    docker-compose -p "$project" -f "$COMPOSE_FILE" --project-directory "${ROOT}/compose" "$@"
  else
    die "docker compose is required (Docker Desktop Compose plugin or docker-compose)"
  fi
}

# Docker Desktop's Linux VM cannot see the Mac GPU. On macOS the shared
# Ollama runs as a host LaunchAgent so Metal can serve qwen3:4b.
ollama_on_host() {
  [[ "${OS:-}" == "macos" ]] || return 1
  case "${NEMOCLAW_PROVIDER:-}" in
    ollama | install-ollama | custom) return 0 ;;
    *) return 1 ;;
  esac
}

listener_pids() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null || true
}

is_docker_listener() {
  local comm cmd
  comm="$(ps -p "$1" -o comm= 2>/dev/null || true)"
  comm="${comm##*/}"
  case "$comm" in
    docker | docker-proxy | com.docker* | vpnkit) return 0 ;;
  esac
  cmd="$(ps -p "$1" -o command= 2>/dev/null || true)"
  case "$cmd" in
    *Docker.app* | *com.docker* | *docker-proxy*) return 0 ;;
  esac
  return 1
}

stop_host_listener() {
  local port="$1"
  local pids pid comm
  pids="$(listener_pids "$port")"
  [[ -n "$pids" ]] || return 0
  for pid in $pids; do
    if is_docker_listener "$pid"; then
      continue
    fi
    comm="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
    printf 'stopping host pid %s (%s) on :%s so Compose can bind it\n' "$pid" "${comm:-unknown}" "$port"
    if [[ "$port" == "11434" ]] && command -v brew >/dev/null; then
      brew services stop ollama >/dev/null 2>&1 || true
    fi
    if [[ "$port" == "8080" || "$port" == "8081" ]] && command -v brew >/dev/null; then
      brew services stop openshell >/dev/null 2>&1 || true
      brew services stop nvidia/openshell/openshell >/dev/null 2>&1 || true
    fi
    kill "$pid" 2>/dev/null || true
  done
}

compose_ports() {
  local port
  for port in 8080 8081 11434 11435 18789; do
    if ollama_on_host && [[ "$port" == "11434" ]]; then
      continue
    fi
    printf '%s\n' "$port"
  done
}

free_compose_ports() {
  local port i pids still_host pid
  while IFS= read -r port; do
    stop_host_listener "$port"
  done < <(compose_ports)
  for i in 1 2 3 4 5 6 7 8 9 10; do
    still_host=0
    while IFS= read -r port; do
      pids="$(listener_pids "$port")"
      for pid in $pids; do
        if ! is_docker_listener "$pid"; then
          still_host=1
        fi
      done
    done < <(compose_ports)
    [[ "$still_host" -eq 0 ]] && return 0
    sleep 1
  done
  die "compose ports are still held by host processes; quit Homebrew OpenShell and rerun"
}

nemoclaw_cmd() {
  run_compose exec -T nemoclaw "$(cli_name)" "$@"
}

# Docker Desktop extra_hosts maps host.openshell.internal to IPv4 and IPv6.
# OpenShell's L7 proxy prefers the IPv6 ULA, which is not in the IPv4
# allowed_ips CIDRs, so inference returns ssrf_denied / HTTP 503.
repair_sandbox_openshell_hosts() {
  local cid
  cid="$(docker ps --filter "name=openshell-default--${NEMOCLAW_SANDBOX_NAME}" --format '{{.ID}}' | head -1)"
  [[ -n "$cid" ]] || return 0
  docker exec -i -u 0 "$cid" python3 - <<'PY'
from pathlib import Path

hosts = Path("/etc/hosts")
out = []
for line in hosts.read_text().splitlines(True):
    stripped = line.lstrip()
    if "host.openshell.internal" in line:
        addr = stripped.split()[0] if stripped.split() else ""
        if ":" in addr and "." not in addr:
            continue
    out.append(line)
hosts.write_text("".join(out))

# Prefer IPv4 when Docker also injects an IPv6 extra_host.
# The stock gai.conf comments out this line; match a marker, not the comment.
gai = Path("/etc/gai.conf")
existing = gai.read_text() if gai.exists() else ""
marker = "# nemoclaw-prefer-ipv4"
if marker not in existing:
    gai.write_text(existing + f"\n{marker}\nprecedence ::ffff:0:0/96  100\n")
PY
}

# Hermes talks to :11435. NemoClaw status still probes https://inference.local
# unless an openai-type cluster route exists. The NemoClaw local profile type
# is not eligible for `openshell inference set`.
ensure_openshell_openai_inference() {
  command -v openshell >/dev/null || return 0
  local token_file="${HOME}/.nemoclaw/ollama-proxy-token"
  local name="nemoclaw-${TARGET}-openai"
  local model="${NEMOCLAW_MODEL:-}"
  local base_url existing
  [[ -n "$model" && -f "$token_file" ]] || return 0
  existing="$(openshell provider list --names 2>/dev/null | grep -E "^(nemoclaw-${TARGET}-openai|${NEMOCLAW_SANDBOX_NAME}-openai|poc-ollama-openai)$" | head -1 || true)"
  [[ -n "$existing" ]] && name="$existing"
  if [[ "${OS:-}" == "macos" ]]; then
    base_url="http://127.0.0.1:11435/v1"
  else
    base_url="http://host.docker.internal:11435/v1"
  fi
  if ! openshell provider list --names 2>/dev/null | grep -qx "$name"; then
    openshell provider create \
      --name "$name" \
      --type openai \
      --credential "OPENAI_API_KEY=$(cat "$token_file")" \
      --config "OPENAI_BASE_URL=${base_url}" >/dev/null
  fi
  if ! openshell inference get 2>/dev/null | grep -q "Provider:"; then
    openshell inference set --provider "$name" --model "$model" --timeout 90
    openshell inference set --system --provider "$name" --model "$model" --timeout 90
  elif ! openshell inference get 2>/dev/null | grep -F "Model: ${model}" >/dev/null; then
    openshell inference set --provider "$name" --model "$model" --timeout 90
    openshell inference set --system --provider "$name" --model "$model" --timeout 90
  fi
  openshell sandbox provider attach "$NEMOCLAW_SANDBOX_NAME" "$name" >/dev/null 2>&1 || true
}

# Keep Hermes on the rewritable placeholder. A frozen
# openshell:resolve:env:vN_... handle breaks after the policy revision changes.
# This does not print the key and does not disable credential inspection.
ensure_hermes_inference_placeholder() {
  local cid changed
  cid="$(docker ps --filter "name=openshell-default--${NEMOCLAW_SANDBOX_NAME}" --format '{{.ID}}' | head -1)"
  [[ -n "$cid" ]] || return 0
  changed="$(docker exec -i -u sandbox -e NEMOCLAW_MODEL="${NEMOCLAW_MODEL:-}" "$cid" python3 - <<'PY'
import json
import os
import re
from pathlib import Path

p = Path("/sandbox/.hermes/config.yaml")
placeholder = "${NEMOCLAW_LOCAL_INFERENCE_TOKEN}"
model = os.environ.get("NEMOCLAW_MODEL", "")
if not p.exists():
    print("0")
    raise SystemExit
raw = p.read_text()
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    text = raw
    orig = text
    text = re.sub(
        r"openshell:resolve:env:\S+_NEMOCLAW_LOCAL_INFERENCE_TOKEN",
        placeholder,
        text,
    )
    if model:
        text = re.sub(r"\bqwen[\w.]+:[\w.-]+\b", model, text)
    if text != orig:
        p.write_text(text)
        print("1")
    else:
        print("0")
    raise SystemExit

changed = False

def is_local(name, obj):
    if "ollama" in name.lower():
        return True
    blob = json.dumps(obj)
    if "11434" in blob or "11435" in blob:
        return True
    for field in ("model", "default"):
        val = obj.get(field)
        if isinstance(val, str) and val.startswith("qwen"):
            return True
    return False

def fix(name, obj):
    global changed
    if not isinstance(obj, dict) or not is_local(name, obj):
        return
    key = obj.get("api_key")
    if not isinstance(key, str) or key != placeholder:
        obj["api_key"] = placeholder
        changed = True
    if not model:
        return
    for field in ("model", "default"):
        val = obj.get(field)
        if isinstance(val, str) and val.startswith("qwen") and val != model:
            obj[field] = model
            changed = True

model_obj = data.get("model")
if isinstance(model_obj, dict):
    fix("model", model_obj)
elif isinstance(model_obj, str) and model and model_obj.startswith("qwen") and model_obj != model:
    data["model"] = model
    changed = True

providers = data.get("providers")
if isinstance(providers, dict):
    for name, obj in providers.items():
        fix(str(name), obj)

custom = data.get("custom_providers")
if isinstance(custom, dict):
    for name, obj in custom.items():
        fix(str(name), obj)
elif isinstance(custom, list):
    for obj in custom:
        if isinstance(obj, dict):
            fix(str(obj.get("name", "")), obj)

if changed:
    p.write_text(json.dumps(data, indent=2) + "\n")
    print("1")
else:
    print("0")
PY
)"
  [[ "$changed" == "1" ]] || return 0
  printf 'rewrote Hermes inference placeholder in %s; restarting gateway\n' "$NEMOCLAW_SANDBOX_NAME"
  if command -v "$(cli_name)" >/dev/null; then
    run_with_timeout 60 "$(cli_name)" "$NEMOCLAW_SANDBOX_NAME" gateway restart >/dev/null || true
  fi
}

# Enable body rewrite on the existing :11435 endpoint. Does not add an
# endpoint that is not already there, and does not allow uninspected credentials.
enable_inference_body_rewrite() {
  local policy decision snapshot
  command -v openshell >/dev/null || die "openshell is required to enable inference body rewrite"
  policy="$(openshell policy get "$NEMOCLAW_SANDBOX_NAME" 2>/dev/null || true)"
  snapshot="$(mktemp)"
  chmod 600 "$snapshot"
  printf '%s\n' "$policy" >"$snapshot"
  set +e
  decision="$(python3 - "$snapshot" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
chunks = re.split(r"\n(?=\s*-\s)", text)
found = False
for chunk in chunks:
    if "host.openshell.internal" not in chunk:
        continue
    if not re.search(r"(port:\s*11435\b|host\.openshell\.internal:11435\b)", chunk):
        continue
    found = True
    if re.search(r"request_body_credential_rewrite:\s*true\b", chunk):
        print("ready")
    else:
        print("enable")
    break
if not found:
    print("absent")
PY
)"
  local py_status=$?
  set -e
  rm -f "$snapshot"
  [[ "$py_status" -eq 0 ]] || die "failed to read OpenShell policy for ${NEMOCLAW_SANDBOX_NAME}"
  case "$decision" in
    ready) return 0 ;;
    enable)
      openshell policy update "$NEMOCLAW_SANDBOX_NAME" \
        --add-endpoint "host.openshell.internal:11435:read-write:rest:enforce:request-body-credential-rewrite,allowed-ip=10.0.0.0/8,allowed-ip=172.16.0.0/12,allowed-ip=192.168.0.0/16" \
        --wait --timeout 60
      ;;
    *)
      die "inference body rewrite is off and host.openshell.internal:11435 is not an existing policy endpoint"
      ;;
  esac
}

probe_sandbox_inference() {
  local cid result attempt
  case "${NEMOCLAW_ACTION:-}" in
    onboard | upgrade) ;;
    *) return 0 ;;
  esac
  cid="$(docker ps --filter "name=openshell-default--${NEMOCLAW_SANDBOX_NAME}" --format '{{.ID}}' | head -1)"
  [[ -n "$cid" ]] || return 0
  for attempt in 1 2; do
    result="$(docker exec -i -u sandbox -e NEMOCLAW_MODEL="${NEMOCLAW_MODEL:-qwen3:4b}" "$cid" python3 - <<'PY'
import json
import os
import urllib.error
import urllib.request

model = os.environ.get("NEMOCLAW_MODEL") or "qwen3:4b"
payload = {
    "model": model,
    "messages": [{"role": "user", "content": "Reply with ok."}],
    "max_tokens": 8,
    "api_key": "${NEMOCLAW_LOCAL_INFERENCE_TOKEN}",
}
req = urllib.request.Request(
    "http://host.openshell.internal:11435/v1/chat/completions",
    data=json.dumps(payload).encode(),
    headers={
        "Content-Type": "application/json",
        "Authorization": "Bearer ${NEMOCLAW_LOCAL_INFERENCE_TOKEN}",
    },
)
try:
    with urllib.request.urlopen(req, timeout=180) as resp:
        raw = resp.read().decode("utf-8", "replace")
        code = resp.status
except urllib.error.HTTPError as exc:
    raw = exc.read().decode("utf-8", "replace")
    code = exc.code
except Exception as exc:
    print("error")
    print(type(exc).__name__)
    raise SystemExit
low = raw.lower()
if "ssrf_denied" in low or "ssrf denied" in low:
    print("ssrf_denied")
elif (
    "rewrite is disabled" in low
    or "credential placeholder denied" in low
    or "credential_injection_failed" in low
):
    print("rewrite_denied")
elif code == 200:
    print("ok")
else:
    print("http_%s" % code)
PY
)"
    case "$result" in
      ok)
        printf 'sandbox inference %s returned 200\n' "$NEMOCLAW_SANDBOX_NAME"
        return 0
        ;;
      rewrite_denied)
        if [[ "$attempt" == "1" ]]; then
          printf 'enabling body rewrite on the existing inference endpoint\n'
          enable_inference_body_rewrite
          continue
        fi
        die "inference body rewrite is still denied for ${NEMOCLAW_SANDBOX_NAME}"
        ;;
      ssrf_denied)
        die "sandbox inference was ssrf_denied for ${NEMOCLAW_SANDBOX_NAME}"
        ;;
      *)
        die "sandbox inference probe returned ${result} for ${NEMOCLAW_SANDBOX_NAME}"
        ;;
    esac
  done
}

# Onboard can leave platforms.discord.enabled=false after a failed finalization
# even when DISCORD_BOT_TOKEN is already in the sandbox env.
ensure_hermes_discord_platform() {
  [[ -n "${DISCORD_SERVER_ID:-}" ]] || return 0
  local cid changed
  cid="$(docker ps --filter "name=openshell-default--${NEMOCLAW_SANDBOX_NAME}" --format '{{.ID}}' | head -1)"
  [[ -n "$cid" ]] || return 0
  changed="$(docker exec -u sandbox "$cid" python3 - <<'PY'
import json
from pathlib import Path
p = Path("/sandbox/.hermes/config.yaml")
if not p.exists():
    print("0")
    raise SystemExit
raw = p.read_text()
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    print("0")
    raise SystemExit
plat = data.setdefault("platforms", {})
disc = plat.setdefault("discord", {})
discord = data.setdefault("discord", {})
changed = False
if disc.get("enabled") is not True:
    disc["enabled"] = True
    changed = True
if discord.get("require_mention") is not True:
    discord["require_mention"] = True
    discord.setdefault("auto_thread", True)
    discord.setdefault("reactions", True)
    changed = True
if changed:
    p.write_text(json.dumps(data, indent=2) + "\n")
    print("1")
else:
    print("0")
PY
)"
  [[ "$changed" == "1" ]] || return 0
  printf 'enabled Hermes Discord platform in %s; recovering gateway\n' "$NEMOCLAW_SANDBOX_NAME"
  if command -v "$(cli_name)" >/dev/null; then
    host_nemoclaw_cmd "$NEMOCLAW_SANDBOX_NAME" recover >/dev/null
  fi
}

host_nemoclaw_cmd() {
  local cli
  cli="$(cli_name)"
  command -v "$cli" >/dev/null || die "${cli} is not on PATH; install NemoClaw on this machine first"
  "$cli" "$@"
}

onboard_session_file() {
  local f
  for f in \
    "${HOME}/.nemoclaw/onboard-session.json" \
    "${HOME}"/.nemoclaw/*/onboard-session.json \
    "${HOME}"/.nemoclaw/gateways/*/onboard-session.json
  do
    if [[ -f "$f" ]]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

# none | resumable | stale
classify_onboard_session() {
  local file status
  file="$(onboard_session_file || true)"
  [[ -n "$file" ]] || { printf 'none\n'; return 0; }
  status="$(python3 -c '
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path))
except Exception:
    print("stale")
    raise SystemExit
raw = data.get("status") or data.get("state") or data.get("phase") or ""
if data.get("resumable") is True:
    print("resumable")
    raise SystemExit
text = str(raw).lower()
if text in ("in_progress", "in-progress", "interrupted", "incomplete"):
    print("resumable")
elif text in ("complete", "completed", "success"):
    print("none")
else:
    print("stale")
' "$file" 2>/dev/null || printf 'stale\n')"
  printf '%s\n' "$status"
}

# absent | error | ready | unknown
# Prefer `openshell sandbox get`. `nemohermes status` probes inference.local
# and can hang for minutes even when OpenShell phase is Ready.
classify_host_sandbox() {
  local log rc=0 cid phase
  export PATH="/opt/homebrew/bin:${HOME}/.nemoclaw/openshell/bin:/opt/homebrew/opt/node@22/bin:${HOME}/.local/bin:${PATH}"
  cid="$(sandbox_container_id)"
  log="$(mktemp)"
  if command -v openshell >/dev/null 2>&1; then
    set +e
    run_with_timeout 15 openshell sandbox get "$NEMOCLAW_SANDBOX_NAME" >"$log" 2>&1
    rc=$?
    set -e
    if grep -Ei 'does not exist|not found|no sandbox' "$log" >/dev/null; then
      rm -f "$log"
      if [[ -n "$cid" ]]; then
        printf 'unknown\n'
      else
        printf 'absent\n'
      fi
      return 0
    fi
    if [[ "$rc" -eq 0 ]] || grep -qiE 'Phase:' "$log"; then
      phase="$(sed $'s/\x1b\\[[0-9;]*[[:alpha:]]//g' "$log" | grep -Ei '^[[:space:]]*Phase:' | tail -n 1 | awk '{print tolower($2)}' || true)"
      rm -f "$log"
      case "$phase" in
        ready) printf 'ready\n'; return 0 ;;
        error) printf 'error\n'; return 0 ;;
        *)
          if [[ -n "$cid" ]]; then
            printf 'unknown\n'
          elif [[ -n "$phase" ]]; then
            printf 'unknown\n'
          else
            printf 'absent\n'
          fi
          return 0
          ;;
      esac
    fi
    printf 'classify sandbox: openshell sandbox get failed; rc=%s\n' "$rc" >&2
  fi
  rm -f "$log"
  if [[ -n "$cid" ]]; then
    printf 'unknown\n'
  else
    printf 'absent\n'
  fi
}

verify_sandbox() {
  local cli
  printf 'verifying sandbox %s\n' "$NEMOCLAW_SANDBOX_NAME"
  repair_sandbox_openshell_hosts
  ensure_openshell_openai_inference
  ensure_hermes_inference_placeholder
  ensure_hermes_discord_platform
  probe_sandbox_inference
  export PATH="/opt/homebrew/opt/node@22/bin:${HOME}/.local/bin:${PATH}"
  cli="$(cli_name)"
  if run_compose exec -T nemoclaw true >/dev/null 2>&1; then
    nemoclaw_cmd "$NEMOCLAW_SANDBOX_NAME" status
    nemoclaw_cmd "$NEMOCLAW_SANDBOX_NAME" connect --probe-only
  else
    command -v "$cli" >/dev/null || die "${cli} is not on PATH; install NemoClaw on this machine first"
    run_with_timeout 90 "$cli" "$NEMOCLAW_SANDBOX_NAME" status
    run_with_timeout 90 "$cli" "$NEMOCLAW_SANDBOX_NAME" connect --probe-only
  fi
  printf 'sandbox %s is healthy\n' "$NEMOCLAW_SANDBOX_NAME"
}

load_target() {
  require_target "$1"
  load_config
  assert_host_os
}
