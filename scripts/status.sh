#!/usr/bin/env bash
# Report Ollama, OpenShell gateway, and sandbox health separately.
# Does not print dashboard URLs or gateway tokens.
# Usage: ./scripts/status.sh <target>

set +x
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

TARGET="${1:-}"
load_target "$TARGET"
assert_not_actions_worktree
preflight_host
acquire_deploy_lock
trap 'release_deploy_lock' EXIT

printf 'status %s\n' "$TARGET"
health_ollama
health_gateway
health_sandbox
printf 'status %s: healthy\n' "$TARGET"
