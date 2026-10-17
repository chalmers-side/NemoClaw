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
    if [[ -n "$cred" ]] || [[ -n "${DISCORD_SERVER_ID:-}" ]] || [[ "${NEMOCLAW_WEB_SEARCH_PROVIDER}" == "tavily" || "${NEMOCLAW_WEB_SEARCH_PROVIDER}" == "brave" ]]; then
      die "missing ${SECRETS_FILE} (copy personal_config/secrets.env.example to personal_config/${TARGET}/secrets.env and fill it)"
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

preflight_host() {
  export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
  command -v docker >/dev/null || die "docker is required"
  if [[ "$OS" == "linux" ]]; then
    docker info >/dev/null || die "docker info failed; the deploying user must be able to talk to Docker"
  elif [[ "$OS" == "macos" ]]; then
    if ! docker info >/dev/null 2>&1; then
      die "Docker Desktop is not running. Open it, wait until docker info works, then rerun."
    fi
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

export_compose_env() {
  export NEMOCLAW_TARGET="${TARGET:?}"
  export NEMOCLAW_ACTION="${NEMOCLAW_ACTION:-serve}"
  export NEMOCLAW_INSTALL_REF
  export OPENSHELL_VERSION
  export OPENSHELL_IMAGE_TAG
  export HOME
}

run_compose() {
  export_compose_env
  mkdir -p "${HOME}/.ollama"
  if docker compose version >/dev/null 2>&1; then
    docker compose -f "$COMPOSE_FILE" --project-directory "${ROOT}/compose" "$@"
  elif command -v docker-compose >/dev/null; then
    docker-compose -f "$COMPOSE_FILE" --project-directory "${ROOT}/compose" "$@"
  else
    die "docker compose is required (Docker Desktop Compose plugin or docker-compose)"
  fi
}

listener_pids() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null || true
}

is_docker_listener() {
  local comm
  comm="$(ps -p "$1" -o comm= 2>/dev/null || true)"
  case "$comm" in
    docker | docker-proxy | com.docker* | vpnkit) return 0 ;;
    *) return 1 ;;
  esac
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

free_compose_ports() {
  local port i pids still_host pid
  for port in 8080 8081 11434 11435 18789; do
    stop_host_listener "$port"
  done
  for i in 1 2 3 4 5 6 7 8 9 10; do
    still_host=0
    for port in 8080 8081 11434 11435 18789; do
      pids="$(listener_pids "$port")"
      for pid in $pids; do
        if ! is_docker_listener "$pid"; then
          still_host=1
        fi
      done
    done
    [[ "$still_host" -eq 0 ]] && return 0
    sleep 1
  done
  die "compose ports are still held by host processes; quit Homebrew OpenShell/Ollama and rerun"
}

nemoclaw_cmd() {
  run_compose exec -T nemoclaw "$(cli_name)" "$@"
}

verify_sandbox() {
  printf 'verifying sandbox %s\n' "$NEMOCLAW_SANDBOX_NAME"
  nemoclaw_cmd "$NEMOCLAW_SANDBOX_NAME" status
  nemoclaw_cmd "$NEMOCLAW_SANDBOX_NAME" connect --probe-only
  printf 'sandbox %s is healthy\n' "$NEMOCLAW_SANDBOX_NAME"
}

load_target() {
  require_target "$1"
  load_config
  assert_host_os
}
