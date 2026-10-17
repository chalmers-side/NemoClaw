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

free_compose_ports
NEMOCLAW_ACTION="$ACTION"
export NEMOCLAW_ACTION

printf 'starting compose stack for %s (%s)\n' "$TARGET" "$ACTION"
run_compose up -d --build init gateway ollama
ensure_local_llm
run_compose up -d --build --force-recreate nemoclaw

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

wait_for_controller
printf 'compose stack is up for %s\n' "$TARGET"
