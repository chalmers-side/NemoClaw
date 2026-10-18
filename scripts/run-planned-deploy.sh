#!/usr/bin/env bash
# Sync is done by the caller. Plan host stages for one target and run them.
# Daily path never onboards, resumes, or recreates a sandbox.
# Usage: ./scripts/run-planned-deploy.sh <target>
# Do not enable xtrace; keys must not enter logs.

set +x
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

TARGET="${1:-}"
[[ -n "$TARGET" ]] || die "usage: $0 <target>"
load_target "$TARGET"
assert_not_actions_worktree
acquire_deploy_lock
trap 'release_deploy_lock' EXIT

plan="$(bash "${SCRIPT_DIR}/plan-deploy.sh" "$TARGET" | tail -n 1)"
if [[ -z "$plan" ]]; then
  printf 'no host stages need rebuild for %s\n' "$TARGET"
else
  printf 'planned host stages for %s: %s\n' "$TARGET" "$plan"
  for action in $plan; do
    case "$action" in
      ollama | nemoclaw) ;;
      onboard | upgrade | sandbox | recover)
        die "daily deploy must not run '${action}'. Use First deploy or Recover."
        ;;
      *)
        die "daily deploy refused unknown stage '${action}'"
        ;;
    esac
    bash "${SCRIPT_DIR}/deploy.sh" "$TARGET" "$action"
  done
fi

printf 'syncing config and running health checks for %s\n' "$TARGET"
sync_sandbox_config
run_health_checks
printf 'planned deploy finished for %s\n' "$TARGET"
