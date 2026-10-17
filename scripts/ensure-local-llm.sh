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

OLLAMA_CONTAINER="${OLLAMA_CONTAINER:-nemoclaw-ollama}"

is_local_ollama_provider() {
  case "${NEMOCLAW_PROVIDER}" in
    ollama | install-ollama | custom) return 0 ;;
    *) return 1 ;;
  esac
}

ollama_http_ok() {
  curl -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1
}

pull_model() {
  local model="${NEMOCLAW_MODEL:-}"
  [[ -n "$model" ]] || die "NEMOCLAW_MODEL is required for the shared Docker LLM"
  printf 'pulling shared model %s inside %s\n' "$model" "$OLLAMA_CONTAINER"
  docker exec "$OLLAMA_CONTAINER" ollama pull "$model"
}

ensure_local_llm() {
  is_local_ollama_provider || return 0
  local i
  for i in $(seq 1 30); do
    if ollama_http_ok; then
      pull_model
      return 0
    fi
    sleep 2
  done
  run_compose logs --tail 80 ollama >&2 || true
  die "Compose Ollama did not become ready on 127.0.0.1:11434"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  free_compose_ports
  run_compose up -d ollama
  ensure_local_llm
fi
