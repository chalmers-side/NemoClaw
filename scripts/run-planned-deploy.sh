#!/usr/bin/env bash
# Sync is done by the caller. Plan stages for one target and run them in order.
# Usage: ./scripts/run-planned-deploy.sh <target>
# Do not enable xtrace; keys must not enter logs.

set +x
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

TARGET="${1:-}"
[[ -n "$TARGET" ]] || die "usage: $0 <target>"
assert_not_actions_worktree

plan="$(bash "${SCRIPT_DIR}/plan-deploy.sh" "$TARGET" | tail -n 1)"
if [[ -z "$plan" ]]; then
  printf 'no stages need rebuild for %s\n' "$TARGET"
  exit 0
fi
printf 'planned stages for %s: %s\n' "$TARGET" "$plan"
for action in $plan; do
  bash "${SCRIPT_DIR}/deploy.sh" "$TARGET" "$action"
done
printf 'planned deploy finished for %s\n' "$TARGET"
