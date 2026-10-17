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

NEMOCLAW_ACTION="$ACTION"
export NEMOCLAW_ACTION

host_onboard_resume_only() {
  printf 'onboarding %s with --resume\n' "$NEMOCLAW_SANDBOX_NAME"
  if ! host_nemoclaw_cmd onboard \
    --non-interactive \
    --yes-i-accept-third-party-software \
    --yes \
    --resume \
    --no-ollama-autostart \
    --agent "$NEMOCLAW_AGENT" \
    --name "$NEMOCLAW_SANDBOX_NAME"; then
    die "onboard --resume failed for ${NEMOCLAW_SANDBOX_NAME}; refusing to create a new sandbox"
  fi
}

host_upgrade_sandboxes() {
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

if ollama_on_host; then
  printf 'starting host Ollama path for %s (%s)\n' "$TARGET" "$ACTION"
  report_docker_desktop_budget
  ensure_homebrew_openshell_gateway
  ensure_local_llm
  install_ollama_auth_proxy_agent
  install_macos_bridge_boot_daemon
  case "$ACTION" in
    onboard) host_onboard_resume_only ;;
    upgrade) host_upgrade_sandboxes ;;
  esac
  verify_sandbox
  printf 'host stack is up for %s\n' "$TARGET"
else
  free_compose_ports
  printf 'starting compose stack for %s (%s)\n' "$TARGET" "$ACTION"
  run_compose up -d --build init gateway ollama
  ensure_local_llm
  run_compose up -d --build --force-recreate nemoclaw
  wait_for_controller
  printf 'compose stack is up for %s\n' "$TARGET"
fi
