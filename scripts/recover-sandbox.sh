#!/usr/bin/env bash
# Repair an existing sandbox. Never create, destroy, or onboard.
# Usage: ./scripts/recover-sandbox.sh <target>

set +x
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

TARGET="${1:-}"
[[ -n "$TARGET" ]] || die "usage: $0 <target>"
bash "${SCRIPT_DIR}/deploy.sh" "$TARGET" recover
