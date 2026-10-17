#!/usr/bin/env bash
# launchd wrapper for the existing NemoClaw Ollama auth proxy.
# The token stays in ~/.nemoclaw/ollama-proxy-token. Do not print it.

set +x
set -euo pipefail

token_file="${HOME}/.nemoclaw/ollama-proxy-token"
script="${HOME}/.nemoclaw/source/scripts/ollama-auth-proxy.mts"
[[ -f "$token_file" && -f "$script" ]] || exit 1

OLLAMA_PROXY_TOKEN="$(tr -d '[:space:]' <"$token_file")"
[[ -n "$OLLAMA_PROXY_TOKEN" ]] || exit 1
export OLLAMA_PROXY_TOKEN
export OLLAMA_PROXY_PORT="${OLLAMA_PROXY_PORT:-11435}"
export OLLAMA_BACKEND_PORT="${OLLAMA_BACKEND_PORT:-11434}"

node=""
if [[ -x /opt/homebrew/bin/node ]]; then
  node=/opt/homebrew/bin/node
elif [[ -x /usr/local/bin/node ]]; then
  node=/usr/local/bin/node
else
  export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/.local/bin:${PATH:-/usr/bin:/bin}"
  node="$(command -v node || true)"
fi
[[ -n "$node" && -x "$node" ]] || exit 1

exec "$node" --no-warnings "$script"
