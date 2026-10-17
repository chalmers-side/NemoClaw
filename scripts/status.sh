#!/usr/bin/env bash
# Report whether the target sandbox is healthy.
# Does not print dashboard URLs or gateway tokens.
# Usage: ./scripts/status.sh <target>

set +x
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

TARGET="${1:-}"
load_target "$TARGET"
preflight_host

if ! docker ps --filter "name=openshell-default--${NEMOCLAW_SANDBOX_NAME}" --format '{{.ID}}' | grep -q .; then
  die "sandbox is not running. Deploy first: bash ./scripts/deploy.sh ${TARGET} onboard"
fi

verify_sandbox
