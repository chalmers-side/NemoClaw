#!/usr/bin/env bash
# Print the deploy actions that need to run for one target.
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
NEED_SANDBOX=0
SANDBOX_ACTION=upgrade

read_marker() {
  local stage="$1" f
  f="$(deploy_state_dir)/${stage}"
  [[ -f "$f" ]] || return 1
  tr -d '[:space:]' <"$f"
}

commit_in_repo() {
  git -C "$ROOT" cat-file -e "${1}^{commit}" 2>/dev/null
}

ollama_is_up() {
  curl -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1
}

nemohermes_is_up() {
  export PATH="/opt/homebrew/opt/node@22/bin:${HOME}/.local/bin:${PATH}"
  command -v nemohermes >/dev/null 2>&1 && nemohermes --version >/dev/null 2>&1
}

sandbox_is_missing() {
  local log cli
  export PATH="/opt/homebrew/opt/node@22/bin:${HOME}/.local/bin:${PATH}"
  cli="$(cli_name)"
  command -v "$cli" >/dev/null 2>&1 || return 0
  log="$(mktemp)"
  "$cli" "$NEMOCLAW_SANDBOX_NAME" status >"$log" 2>&1 || true
  if grep -F "Sandbox '${NEMOCLAW_SANDBOX_NAME}' does not exist" "$log" >/dev/null; then
    rm -f "$log"
    return 0
  fi
  rm -f "$log"
  return 1
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
      sandbox:NEMOCLAW_VERSION | sandbox:compose/nemoclaw/entrypoint.sh)
        NEED_SANDBOX=1
        ;;
      sandbox:personal_config/"${TARGET}"/config.env)
        if [[ "$(config_value_from_text NEMOCLAW_AGENT "$old_cfg")" != "$(config_value_from_text NEMOCLAW_AGENT "$new_cfg")" ]] \
          || [[ "$(config_value_from_text NEMOCLAW_SANDBOX_NAME "$old_cfg")" != "$(config_value_from_text NEMOCLAW_SANDBOX_NAME "$new_cfg")" ]] \
          || [[ "$(config_value_from_text NEMOCLAW_POLICY_TIER "$old_cfg")" != "$(config_value_from_text NEMOCLAW_POLICY_TIER "$new_cfg")" ]] \
          || [[ "$(config_value_from_text NEMOCLAW_WEB_SEARCH_PROVIDER "$old_cfg")" != "$(config_value_from_text NEMOCLAW_WEB_SEARCH_PROVIDER "$new_cfg")" ]] \
          || [[ "$(config_value_from_text NEMOCLAW_IGNORE_RUNTIME_RESOURCES "$old_cfg")" != "$(config_value_from_text NEMOCLAW_IGNORE_RUNTIME_RESOURCES "$new_cfg")" ]] \
          || [[ "$(config_value_from_text DISCORD_SERVER_ID "$old_cfg")" != "$(config_value_from_text DISCORD_SERVER_ID "$new_cfg")" ]] \
          || [[ "$(config_value_from_text DISCORD_REQUIRE_MENTION "$old_cfg")" != "$(config_value_from_text DISCORD_REQUIRE_MENTION "$new_cfg")" ]] \
          || [[ "$(config_value_from_text DISCORD_USER_ID "$old_cfg")" != "$(config_value_from_text DISCORD_USER_ID "$new_cfg")" ]]; then
          NEED_SANDBOX=1
        fi
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
printf 'planning deploy for %s at %s\n' "$TARGET" "$CURRENT" >&2

if ! read_marker ollama >/dev/null || ! ollama_is_up; then
  NEED_OLLAMA=1
  printf 'ollama: first install or not listening on 11434\n' >&2
else
  old="$(read_marker ollama)"
  if ! commit_in_repo "$old"; then
    NEED_OLLAMA=1
    printf 'ollama: previous SHA %s is not in this clone; rebuild\n' "$old" >&2
  else
    plan_from_diff ollama "$old"
  fi
fi

if ! read_marker nemoclaw >/dev/null || ! nemohermes_is_up; then
  NEED_NEMOCLAW=1
  printf 'nemoclaw: first install or nemohermes missing\n' >&2
else
  old="$(read_marker nemoclaw)"
  if ! commit_in_repo "$old"; then
    NEED_NEMOCLAW=1
    printf 'nemoclaw: previous SHA %s is not in this clone; rebuild\n' "$old" >&2
  else
    plan_from_diff nemoclaw "$old"
  fi
fi

if sandbox_is_missing; then
  NEED_SANDBOX=1
  SANDBOX_ACTION=onboard
  printf 'sandbox: missing; onboard\n' >&2
elif ! read_marker sandbox >/dev/null; then
  NEED_SANDBOX=1
  SANDBOX_ACTION=onboard
  printf 'sandbox: no marker; onboard\n' >&2
else
  SANDBOX_ACTION=upgrade
  old="$(read_marker sandbox)"
  if ! commit_in_repo "$old"; then
    NEED_SANDBOX=1
    printf 'sandbox: previous SHA %s is not in this clone; upgrade\n' "$old" >&2
  else
    plan_from_diff sandbox "$old"
  fi
fi

# plan_from_diff may set NEED_* from a later stage's file list; keep
# sandbox as upgrade when the sandbox already exists.
if ! sandbox_is_missing && [[ -f "$(deploy_state_dir)/sandbox" ]]; then
  SANDBOX_ACTION=upgrade
fi

actions=()
if [[ "$NEED_OLLAMA" -eq 1 ]]; then
  actions+=(ollama)
fi
if [[ "$NEED_NEMOCLAW" -eq 1 ]]; then
  actions+=(nemoclaw)
fi
if [[ "$NEED_SANDBOX" -eq 1 ]]; then
  actions+=("$SANDBOX_ACTION")
fi

if [[ "${#actions[@]}" -eq 0 ]]; then
  printf 'no stages need rebuild\n' >&2
  exit 0
fi
printf '%s\n' "${actions[*]}"
