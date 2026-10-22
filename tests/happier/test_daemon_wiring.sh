#!/usr/bin/env bash
# shellcheck disable=SC2034 # globals here are read by the eval-extracted functions
# write_daemon_env_dropin (N2: explicit unit, so from_source's stack unit is
# wired too) and install_auto_update_timer, extracted from
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
  FAKE_CLAUDE="/usr/local/bin/claude"
  FAKE_CODEX=""
  DAEMON_GITHUB_PAT=""
}

test_from_source_stack_unit_gets_dropin() {
  reset
  write_daemon_env_dropin "dev.happier.stack.service" "hstack start --restart" >/dev/null
  local conf="${SYSTEMD_UNIT_DIR}/dev.happier.stack.service.d/10-happier-agents.conf"
  assert_ok "drop-in written for the stack unit" test -f "${conf}"
  assert_ok "claude path wired" grep -q '^Environment="HAPPIER_CLAUDE_PATH=/usr/local/bin/claude"$' "${conf}"
  assert_eq "$(stat -c %a "${conf}")" "600" "drop-in is 600"
  assert_ok "unit restarted" grep -q '^systemctl restart dev.happier.stack.service$' "${SB}/systemctl.log"
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
