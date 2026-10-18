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
    <string>5m</string>
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
  launchctl_bootstrap_gui "com.nemoclaw.ollama" "$plist"
}

pull_model() {
  local model="${NEMOCLAW_MODEL:-}"
  [[ -n "$model" ]] || die "NEMOCLAW_MODEL is required for the shared local LLM"
  if ollama_on_host; then
    printf 'pulling shared model %s on the host Ollama (timeout 600s)\n' "$model"
    run_with_timeout 600 "$(brew --prefix)/bin/ollama" pull "$model"
    return 0
  fi
  printf 'pulling shared model %s inside %s (timeout 600s)\n' "$model" "$OLLAMA_CONTAINER"
  run_with_timeout 600 docker exec "$OLLAMA_CONTAINER" ollama pull "$model"
}

ensure_local_llm() {
  is_local_ollama_provider || return 0
  local i
  if ollama_on_host; then
    stop_compose_ollama
    start_host_ollama
  fi
  printf 'waiting for Ollama on 127.0.0.1:11434 (timeout 120s)\n'
  for i in $(seq 1 60); do
    if ollama_http_ok; then
      printf 'Ollama is up after %ss\n' "$((i * 2))"
      pull_model
      return 0
    fi
    if [[ $((i % 10)) -eq 0 ]]; then
      printf 'still waiting for Ollama (%ss / 120s)\n' "$((i * 2))"
    fi
    sleep 2
  done
  if ollama_on_host; then
    die "host Ollama did not become ready on 127.0.0.1:11434. $(tail -n 30 "${HOME}/Library/Logs/nemoclaw-ollama.log" 2>/dev/null || true)"
  fi
  run_compose logs --tail 80 ollama >&2 || true
  die "Compose Ollama did not become ready on 127.0.0.1:11434"
}

# User LaunchAgent. The plist points at the wrapper; the token stays in the
# token file and is not written into the plist.
ensure_pinned_ollama_auth_proxy() {
  local dest pin url
  dest="${HOME}/.nemoclaw/source/scripts/ollama-auth-proxy.mts"
  [[ -s "$dest" ]] && return 0
  pin="1e82499a048d5a4d85b0876d8c07bd93c8a9a5de"
  url="https://raw.githubusercontent.com/NVIDIA/NemoClaw/${pin}/scripts/ollama-auth-proxy.mts"
  mkdir -p "${HOME}/.nemoclaw/source/scripts"
  curl -fsSL "$url" -o "$dest" || die "could not download the pinned Ollama auth proxy"
  [[ -s "$dest" ]] || die "downloaded Ollama auth proxy is empty"
}

ensure_node_for_auth_proxy() {
  local bin major
  for bin in /opt/homebrew/bin/node /opt/homebrew/opt/node@22/bin/node /usr/local/bin/node; do
    [[ -x "$bin" ]] || continue
    major="$("$bin" -p "process.versions.node.split('.')[0]" 2>/dev/null || true)"
    if [[ "$major" =~ ^[0-9]+$ && "$major" -ge 22 ]]; then
      return 0
    fi
  done
  command -v brew >/dev/null || die "Homebrew is required to install Node 22 for the Ollama auth proxy"
  brew install node@22
}

install_ollama_auth_proxy_agent() {
  local uid plist script
  [[ "$(uname -s)" == "Darwin" ]] || return 0
  uid="$(id -u)"
  script="${ROOT}/scripts/ollama-auth-proxy-agent.sh"
  [[ -f "$script" ]] || die "missing ${script}"
  chmod 755 "$script"
  mkdir -p "${HOME}/.nemoclaw"
  if [[ ! -f "${HOME}/.nemoclaw/ollama-proxy-token" ]]; then
    umask 077
    openssl rand -hex 32 >"${HOME}/.nemoclaw/ollama-proxy-token"
  fi
  chmod 600 "${HOME}/.nemoclaw/ollama-proxy-token" || true
  ensure_node_for_auth_proxy
  ensure_pinned_ollama_auth_proxy
  [[ -f "${HOME}/.nemoclaw/source/scripts/ollama-auth-proxy.mts" ]] ||
    die "missing ${HOME}/.nemoclaw/source/scripts/ollama-auth-proxy.mts"
  mkdir -p "${HOME}/Library/LaunchAgents" "${HOME}/Library/Logs"
  plist="${HOME}/Library/LaunchAgents/com.nemoclaw.ollama-auth-proxy.plist"
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.nemoclaw.ollama-auth-proxy</string>
  <key>ProgramArguments</key>
  <array>
    <string>${script}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${HOME}/Library/Logs/nemoclaw-ollama-auth-proxy.log</string>
  <key>StandardErrorPath</key>
  <string>${HOME}/Library/Logs/nemoclaw-ollama-auth-proxy.log</string>
</dict>
</plist>
EOF
  launchctl_bootstrap_gui "com.nemoclaw.ollama-auth-proxy" "$plist"
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
