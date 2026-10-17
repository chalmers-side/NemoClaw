#!/usr/bin/env bash
# Pull NEMOCLAW_MODEL into the Compose Ollama service.
# Usage: ./scripts/ensure-local-llm.sh <target>
# Sourced from deploy.sh, or run directly.

set +x
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${ROOT:-}" ]]; then
  # shellcheck source=scripts/common.sh
  source "${SCRIPT_DIR}/common.sh"
  load_target "${1:?usage: ensure-local-llm.sh <target>}"
  preflight_host
fi

OLLAMA_CONTAINER="${OLLAMA_CONTAINER:-NemoClaw-${TARGET}-ollama}"

is_local_ollama_provider() {
  case "${NEMOCLAW_PROVIDER}" in
    ollama | install-ollama | custom) return 0 ;;
    *) return 1 ;;
  esac
}

ollama_http_ok() {
  curl -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1
}

stop_compose_ollama() {
  local id
  id="$(docker ps -q --filter publish=11434)"
  [[ -n "$id" ]] || return 0
  printf 'stopping Compose Ollama so the host daemon can bind :11434\n'
  docker stop $id >/dev/null
}

start_host_ollama() {
  local bin plist uid
  command -v brew >/dev/null || die "Homebrew is required to run Ollama on the Mac GPU"
  if ! brew list --formula ollama >/dev/null 2>&1; then
    brew install ollama
  fi
  bin="$(brew --prefix)/bin/ollama"
  [[ -x "$bin" ]] || die "ollama is not executable at ${bin}"
  uid="$(id -u)"
  plist="${HOME}/Library/LaunchAgents/com.nemoclaw.ollama.plist"
  mkdir -p "${HOME}/Library/LaunchAgents"
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.nemoclaw.ollama</string>
  <key>ProgramArguments</key>
  <array>
    <string>${bin}</string>
    <string>serve</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OLLAMA_HOST</key>
    <string>127.0.0.1:11434</string>
    <key>OLLAMA_CONTEXT_LENGTH</key>
    <string>64000</string>
    <key>OLLAMA_FLASH_ATTENTION</key>
    <string>1</string>
    <key>OLLAMA_KV_CACHE_TYPE</key>
    <string>q4_0</string>
    <key>OLLAMA_MAX_LOADED_MODELS</key>
    <string>1</string>
    <key>OLLAMA_NUM_PARALLEL</key>
    <string>1</string>
    <key>OLLAMA_KEEP_ALIVE</key>
    <string>-1</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${HOME}/Library/Logs/nemoclaw-ollama.log</string>
  <key>StandardErrorPath</key>
  <string>${HOME}/Library/Logs/nemoclaw-ollama.log</string>
</dict>
</plist>
EOF
  brew services stop ollama >/dev/null 2>&1 || true
  launchctl bootout "gui/${uid}/com.nemoclaw.ollama" >/dev/null 2>&1 || true
  local attempt
  for attempt in 1 2 3; do
    if launchctl bootstrap "gui/${uid}" "$plist"; then
      break
    fi
    # bootout can still be tearing the job down; a second bootstrap then succeeds.
    sleep 1
    launchctl bootout "gui/${uid}/com.nemoclaw.ollama" >/dev/null 2>&1 || true
    if [[ "$attempt" == "3" ]]; then
      die "failed to bootstrap com.nemoclaw.ollama"
    fi
  done
  launchctl enable "gui/${uid}/com.nemoclaw.ollama" >/dev/null 2>&1 || true
}

pull_model() {
  local model="${NEMOCLAW_MODEL:-}"
  [[ -n "$model" ]] || die "NEMOCLAW_MODEL is required for the shared local LLM"
  if ollama_on_host; then
    printf 'pulling shared model %s on the host Ollama\n' "$model"
    "$(brew --prefix)/bin/ollama" pull "$model"
    return 0
  fi
  printf 'pulling shared model %s inside %s\n' "$model" "$OLLAMA_CONTAINER"
  docker exec "$OLLAMA_CONTAINER" ollama pull "$model"
}

ensure_local_llm() {
  is_local_ollama_provider || return 0
  local i
  if ollama_on_host; then
    stop_compose_ollama
    start_host_ollama
  fi
  for i in $(seq 1 30); do
    if ollama_http_ok; then
      pull_model
      return 0
    fi
    sleep 2
  done
  if ollama_on_host; then
    die "host Ollama did not become ready on 127.0.0.1:11434"
  fi
  run_compose logs --tail 80 ollama >&2 || true
  die "Compose Ollama did not become ready on 127.0.0.1:11434"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if ollama_on_host; then
    ensure_local_llm
  else
    free_compose_ports
    run_compose up -d ollama
    ensure_local_llm
  fi
fi
