#!/usr/bin/env bash
# Print the daily host stages that need to run for one target.
# Never prints onboard, upgrade, or recover.
# Usage: ./scripts/plan-deploy.sh <target>
# Stdout is a space-separated list (possibly empty). Reasons go to stderr.
# Do not print secrets.

set +x
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

TARGET="${1:-}"
load_target "$TARGET"
assert_not_actions_worktree

NEED_OLLAMA=0
NEED_NEMOCLAW=0

read_marker() {
  local stage="$1" f
  f="$(deploy_state_dir)/${stage}"
  [[ -f "$f" ]] || return 1
  tr -d '[:space:]' <"$f"
}

commit_in_repo() {
  git -C "$ROOT" cat-file -e "${1}^{commit}" 2>/dev/null
}

config_value_from_text() {
  local key="$1" text="$2"
  printf '%s\n' "$text" | grep -E "^${key}=" | tail -n 1 | sed "s/^${key}=//"
}

config_at_sha() {
  git -C "$ROOT" show "${1}:personal_config/${TARGET}/config.env" 2>/dev/null || true
}

plan_from_diff() {
  local stage="$1" old="$2" files f old_cfg new_cfg
  files="$(git -C "$ROOT" diff --name-only "$old" "$CURRENT" || true)"
  [[ -n "$files" ]] || return 0
  old_cfg="$(config_at_sha "$old")"
  new_cfg="$(cat "${ROOT}/personal_config/${TARGET}/config.env")"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    case "$stage:$f" in
      ollama:scripts/ensure-local-llm.sh)
        NEED_OLLAMA=1
        ;;
      ollama:personal_config/"${TARGET}"/config.env)
        if [[ "$(config_value_from_text NEMOCLAW_MODEL "$old_cfg")" != "$(config_value_from_text NEMOCLAW_MODEL "$new_cfg")" ]] \
          || [[ "$(config_value_from_text NEMOCLAW_PROVIDER "$old_cfg")" != "$(config_value_from_text NEMOCLAW_PROVIDER "$new_cfg")" ]] \
          || [[ "$(config_value_from_text OS "$old_cfg")" != "$(config_value_from_text OS "$new_cfg")" ]]; then
          NEED_OLLAMA=1
        fi
        ;;
      nemoclaw:NEMOCLAW_VERSION | nemoclaw:OPENSHELL_VERSION | nemoclaw:scripts/common.sh | \
      nemoclaw:scripts/macos-openshell-bridge.sh | nemoclaw:scripts/ollama-auth-proxy-agent.sh)
        NEED_NEMOCLAW=1
        ;;
    esac
    if [[ "$stage" == "nemoclaw" && "$OS" == "linux" ]]; then
      case "$f" in
        compose/docker-compose.yml | compose/gateway.toml | compose/nemoclaw/Dockerfile)
          NEED_NEMOCLAW=1
          ;;
      esac
    fi
  done <<EOF
$files
EOF
}

CURRENT="$(current_deploy_sha)"
printf 'planning daily deploy for %s at %s (never onboard or upgrade-sandboxes)\n' "$TARGET" "$CURRENT" >&2

if old="$(read_marker ollama)"; then
  if ! commit_in_repo "$old"; then
    NEED_OLLAMA=1
    printf 'ollama: previous SHA %s is not in this clone; rebuild host tools\n' "$old" >&2
  else
    plan_from_diff ollama "$old"
  fi
else
  printf 'ollama: no marker; skip host stage (health check will fail if 11434 is down)\n' >&2
fi

if old="$(read_marker nemoclaw)"; then
  if ! commit_in_repo "$old"; then
    NEED_NEMOCLAW=1
    printf 'nemoclaw: previous SHA %s is not in this clone; rebuild host tools\n' "$old" >&2
  else
    plan_from_diff nemoclaw "$old"
  fi
else
  printf 'nemoclaw: no marker; skip host stage (health check will fail if gateway is down)\n' >&2
fi

printf 'sandbox: daily deploy never plans onboard or upgrade\n' >&2

actions=()
if [[ "$NEED_OLLAMA" -eq 1 ]]; then
  actions+=(ollama)
fi
if [[ "$NEED_NEMOCLAW" -eq 1 ]]; then
  actions+=(nemoclaw)
fi

if [[ "${#actions[@]}" -eq 0 ]]; then
  printf 'no stages need rebuild\n' >&2
  exit 0
fi
printf '%s\n' "${actions[*]}"
