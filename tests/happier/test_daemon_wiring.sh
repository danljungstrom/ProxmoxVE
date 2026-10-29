#!/usr/bin/env bash
# shellcheck disable=SC2034 # globals here are read by the eval-extracted functions
# Daemon environment persistence and install_auto_update_timer, extracted from
# install/happier-install.sh and pointed at a sandbox SYSTEMD_UNIT_DIR.
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091 # test-local helper, resolved at runtime
source ./lib.sh

INSTALL_SH="../../install/happier-install.sh"
msg_warn() { echo "WARN: $*"; }
msg_error() { echo "ERR: $*"; }
msg_info() { :; }
msg_ok() { :; }
eval "$(grep '^is_valid_github_pat()' "${INSTALL_SH}")"
eval "$(extract_function "${INSTALL_SH}" write_daemon_env_dropin)"
eval "$(extract_function "${INSTALL_SH}" set_env_kv)"
eval "$(extract_function "${INSTALL_SH}" install_auto_update_timer)"
eval "$(grep '^AUTO_UPDATE_UNIT=' "${INSTALL_SH}")"

SB="$(mktemp -d)"
trap 'rm -rf "${SB}"' EXIT
SYSTEMD_UNIT_DIR="${SB}/systemd"
STD=""

# Top-level stubs: claude/codex resolution and systemctl.
command() {
  if [[ "$1" == "-v" ]]; then
    case "$2" in
      claude) [[ -n "${FAKE_CLAUDE:-}" ]] && printf '%s\n' "${FAKE_CLAUDE}" && return 0 ;;
      codex) [[ -n "${FAKE_CODEX:-}" ]] && printf '%s\n' "${FAKE_CODEX}" && return 0 ;;
    esac
    return 1
  fi
  builtin command "$@"
}
systemctl() { echo "systemctl $*" >>"${SB}/systemctl.log"; }

reset() {
  rm -rf "${SYSTEMD_UNIT_DIR}" "${SB}/systemctl.log"
  mkdir -p "${SYSTEMD_UNIT_DIR}"
  HAPPIER_HOME="${SB}/home"
  rm -rf "${HAPPIER_HOME}"
  mkdir -p "${HAPPIER_HOME}/.local/bin"
  STACK_ENV_FILE="${HAPPIER_HOME}/stack.env"
  touch "${STACK_ENV_FILE}"
  chmod 600 "${STACK_ENV_FILE}"
  INSTALL_METHOD="installers"
  FAKE_CLAUDE="/usr/local/bin/claude"
  FAKE_CODEX=""
  DAEMON_GITHUB_PAT=""
}

test_managed_service_gets_dropin() {
  reset
  write_daemon_env_dropin "happier-daemon.default.service" "happier daemon start" >/dev/null
  local conf="${SYSTEMD_UNIT_DIR}/happier-daemon.default.service.d/10-happier-agents.conf"
  assert_ok "drop-in written for the managed daemon" test -f "${conf}"
  assert_ok "claude path wired" grep -q '^Environment="HAPPIER_CLAUDE_PATH=/usr/local/bin/claude"$' "${conf}"
  assert_eq "$(stat -c %a "${conf}")" "600" "drop-in is 600"
  assert_ok "unit try-restarted (never started if stopped)" grep -q '^systemctl try-restart happier-daemon.default.service$' "${SB}/systemctl.log"
}

test_from_source_environment_is_persisted_before_startup() {
  reset
  INSTALL_METHOD="from_source"
  FAKE_CODEX="/usr/local/bin/codex"
  DAEMON_GITHUB_PAT="ghp_TESTTOKEN123"
  write_daemon_env_dropin "" "hstack start --restart" >/dev/null
  # The stack loads this same env file for manual and service starts. Observe
  # the persisted values in a fresh process, without the installer's exports.
  local inherited
  # shellcheck disable=SC2016 # the fresh process expands its loaded environment
  inherited="$(env -i bash -c 'set -a; source "$1"; printf "%s|%s|%s|%s" "${HAPPIER_CLAUDE_PATH:-}" "${HAPPIER_CODEX_PATH:-}" "${GH_TOKEN:-}" "${GITHUB_PERSONAL_ACCESS_TOKEN:-}"' bash "${STACK_ENV_FILE}")"
  assert_eq "${inherited}" "/usr/local/bin/claude|/usr/local/bin/codex|ghp_TESTTOKEN123|ghp_TESTTOKEN123" "source daemon inherits persisted env"
  assert_eq "$(stat -c %a "${STACK_ENV_FILE}")" "600" "stack env remains private"
  assert_fail "no systemd action before source stack startup" test -f "${SB}/systemctl.log"
}

test_native_claude_lookup_uses_the_daemon_user_home() {
  reset
  FAKE_CLAUDE=""
  printf '#!/bin/sh\nexit 0\n' >"${HAPPIER_HOME}/.local/bin/claude"
  chmod +x "${HAPPIER_HOME}/.local/bin/claude"
  write_daemon_env_dropin "happier-daemon.service" "x" >/dev/null
  assert_ok "native installer path is wired" grep -Fq "HAPPIER_CLAUDE_PATH=${HAPPIER_HOME}/.local/bin/claude" "${SYSTEMD_UNIT_DIR}/happier-daemon.service.d/10-happier-agents.conf"
}

test_pat_goes_to_root_only_envfile() {
  reset
  DAEMON_GITHUB_PAT="ghp_TESTTOKEN123"
  write_daemon_env_dropin "happier-daemon.service" "x" >/dev/null
  local d="${SYSTEMD_UNIT_DIR}/happier-daemon.service.d"
  assert_fail "token not in the unit fragment" grep -q 'ghp_TESTTOKEN123' "${d}/10-happier-agents.conf"
  assert_ok "fragment references the env file" grep -q "^EnvironmentFile=${d}/10-happier-agents.env$" "${d}/10-happier-agents.conf"
  assert_ok "GH_TOKEN set" grep -q '^GH_TOKEN=ghp_TESTTOKEN123$' "${d}/10-happier-agents.env"
  assert_ok "legacy name kept" grep -q '^GITHUB_PERSONAL_ACCESS_TOKEN=ghp_TESTTOKEN123$' "${d}/10-happier-agents.env"
  assert_eq "$(stat -c %a "${d}/10-happier-agents.env")" "600" "env file is 600"
}

test_invalid_pat_is_dropped() {
  reset
  DAEMON_GITHUB_PAT='bad"token'
  local out
  out="$(write_daemon_env_dropin "happier-daemon.service" "x")"
  assert_ok "warned" grep -q 'outside \[A-Za-z0-9_\]' <<<"${out}"
  assert_fail "no env file" test -f "${SYSTEMD_UNIT_DIR}/happier-daemon.service.d/10-happier-agents.env"
}

test_no_unit_prints_manual_hint() {
  reset
  local out
  out="$(write_daemon_env_dropin "" "sudo -u happier -H hstack start --restart")"
  assert_ok "names the method's start command" grep -q 'before starting it with: sudo -u happier -H hstack start --restart' <<<"${out}"
  assert_ok "prints the claude export" grep -q 'export HAPPIER_CLAUDE_PATH=/usr/local/bin/claude' <<<"${out}"
  assert_eq "$(find "${SYSTEMD_UNIT_DIR}" -mindepth 1 | wc -l)" "0" "nothing written"
}

test_nothing_to_wire_is_a_noop() {
  reset
  FAKE_CLAUDE=""
  local out
  out="$(write_daemon_env_dropin "happier-daemon.service" "x")"
  assert_ok "skips with a warning" grep -q 'skipping daemon env drop-in' <<<"${out}"
}

test_auto_update_timer_units() {
  reset
  AUTO_UPDATE=1
  AUTO_UPDATE_AT="03:30"
  install_auto_update_timer >/dev/null
  local t="${SYSTEMD_UNIT_DIR}/${AUTO_UPDATE_UNIT}.timer" s="${SYSTEMD_UNIT_DIR}/${AUTO_UPDATE_UNIT}.service"
  assert_ok "timer at the chosen time" grep -q '^OnCalendar=\*-\*-\* 03:30:00$' "${t}"
  assert_ok "service runs update unattended" grep -q '^ExecStart=/usr/bin/update$' "${s}"
  assert_ok "PHS_SILENT selects the silent update path" grep -q '^Environment=PHS_SILENT=1$' "${s}"
  assert_ok "timer enabled" grep -q "^systemctl enable --now ${AUTO_UPDATE_UNIT}.timer$" "${SB}/systemctl.log"
}

test_auto_update_off_writes_nothing() {
  reset
  AUTO_UPDATE=0
  install_auto_update_timer
  assert_fail "no timer" test -f "${SYSTEMD_UNIT_DIR}/${AUTO_UPDATE_UNIT}.timer"
}

run_tests
