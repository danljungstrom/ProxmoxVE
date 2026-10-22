#!/usr/bin/env bash
# D2: the installers branch of ct/happier.sh's update_script — CLI update via
# the bootstrap, relay reinstall arguments (env re-pass, --yes, never
# HAPPIER_SERVER_UI_DIR), autostart restore and the daemon unit refresh — plus
# the from_source guidance branch. update_script is extracted by name and run in a subshell (it exits)
# against a fake CLI and a systemctl stub that record what they were asked to do.
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091 # test-local helper, resolved at runtime
source ./lib.sh

CT_SH="../../ct/happier.sh"
msg_warn() { echo "WARN: $*" >>"${LOG}"; }
msg_error() { echo "ERR: $*" >>"${LOG}"; }
msg_info() { :; }
msg_ok() { :; }
# shellcheck disable=SC1091 # unit under test, resolved at runtime
source ../../misc/happier-common.func
eval "$(extract_function "${CT_SH}" update_script)"

SB="$(mktemp -d)"
trap 'rm -rf "${SB}"' EXIT
LOG="${SB}/log"
# shellcheck disable=SC2034 # read by the extracted update_script
APP="Happier"

# --- stubs (top-level so they are not flagged as unreachable) -----------------
header_info() { :; }
check_container_storage() { :; }
check_container_resources() { :; }
detect_installed_channel() { printf '%s' "${FAKE_CHANNEL}"; }
channel_config_env_path() { printf '%s' "${SB}/server.env"; }
resolve_installed_cli_for_channel() { [[ -x "${SB}/cli" ]] && printf '%s' "${SB}/cli"; }
find_happier_daemon_unit() { printf '%s' "${FAKE_DAEMON_UNIT}"; }
restart_happier_unit() { echo "restart $1" >>"${LOG}"; }
install_happier_cli() {
  echo "install_happier_cli $1" >>"${LOG}"
  [[ -n "${FAKE_BOOTSTRAP_BROKEN:-}" ]] && return 1
  make_cli
}
happier_install_daemon_service() { echo "daemon_service $2" >>"${LOG}"; }
# systemctl: is-enabled/is-active answer from FAKE_ENABLED/FAKE_ACTIVE (unit
# names), everything else is logged.
systemctl() {
  case "$1" in
    is-enabled) [[ " ${FAKE_ENABLED} " == *" ${3} "* ]] ;;
    is-active) [[ " ${FAKE_ACTIVE} " == *" ${3} "* ]] ;;
    *) echo "systemctl $*" >>"${LOG}" ;;
  esac
}

make_cli() { # fake CLI: logs its argv, fails `relay host install` when FAKE_RELAY_RC set
  cat >"${SB}/cli" <<EOF
#!/usr/bin/env bash
printf '%s\n' "cli \$*" >>"${LOG}"
[[ "\$1 \$2 \$3" == "relay host install" ]] && exit "\${FAKE_RELAY_RC:-0}"
exit 0
EOF
  chmod +x "${SB}/cli"
}

reset() {
  rm -f "${SB}/cli" "${SB}/server.env"
  : >"${LOG}"
  FAKE_CHANNEL="stable"
  FAKE_DAEMON_UNIT=""
  FAKE_ENABLED="happier-server"
  FAKE_ACTIVE="happier-server"
  FAKE_BOOTSTRAP_BROKEN=""
  unset FAKE_RELAY_RC
  export FAKE_RELAY_RC LOG
}

run_update() { (update_script) >/dev/null 2>&1; }
relay_line() { grep '^cli relay host install' "${LOG}"; }
has_relay_line() { relay_line >/dev/null; }

# --- tests ------------------------------------------------------------------

test_relay_reinstall_args() {
  reset
  make_cli
  cat >"${SB}/server.env" <<'EOF'
HAPPIER_SERVER_HOST=0.0.0.0
PORT="3010"
HAPPIER_PUBLIC_SERVER_URL='https://happier.example.com'
HAPPIER_WEBAPP_URL=
HAPPIER_SERVER_UI_DIR=/opt/happier/ui-web/current
EOF
  assert_ok "update exits 0" run_update
  local line
  line="$(relay_line)"
  assert_eq "${line}" "cli relay host install --mode system --channel stable --yes --env HAPPIER_SERVER_HOST=0.0.0.0 --env PORT=3010 --env HAPPIER_PUBLIC_SERVER_URL=https://happier.example.com" \
    "env re-passed (quotes stripped, empty skipped), --yes, no UI_DIR"
  assert_ok "CLI updated via the bootstrap on the installed channel" grep -q '^install_happier_cli stable$' "${LOG}"
  assert_fail "never via root self update" grep -q '^cli self update' "${LOG}"
}

test_preview_channel_args() {
  reset
  make_cli
  FAKE_CHANNEL="preview"
  FAKE_ENABLED="happier-server-preview"
  FAKE_ACTIVE="happier-server-preview"
  run_update
  assert_eq "$(relay_line)" "cli relay host install --mode system --channel preview --yes" "channel threaded through"
  assert_ok "preview relay restarted" grep -q '^restart happier-server-preview$' "${LOG}"
}

test_autostart_off_is_restored() {
  reset
  make_cli
  FAKE_ENABLED=""
  FAKE_ACTIVE=""
  run_update
  assert_ok "relay disabled again" grep -q '^systemctl disable -q happier-server$' "${LOG}"
  assert_ok "relay stopped again" grep -q '^systemctl stop happier-server$' "${LOG}"
  assert_fail "relay not restarted" grep -q '^restart happier-server$' "${LOG}"
}

test_enabled_but_stopped_stays_stopped() {
  reset
  make_cli
  FAKE_ACTIVE=""
  run_update
  assert_fail "not disabled" grep -q 'disable' "${LOG}"
  assert_ok "stopped again" grep -q '^systemctl stop happier-server$' "${LOG}"
}

test_daemon_unit_refreshed_and_state_kept() {
  reset
  make_cli
  FAKE_DAEMON_UNIT="happier-daemon.service"
  run_update
  assert_ok "unit refreshed with --no-autostart semantics (was disabled)" grep -q '^daemon_service 0$' "${LOG}"
  assert_fail "inactive daemon not restarted" grep -q '^restart happier-daemon.service$' "${LOG}"
  assert_ok "inactive daemon stopped again" grep -q '^systemctl stop happier-daemon.service$' "${LOG}"
  reset
  make_cli
  FAKE_DAEMON_UNIT="happier-daemon.service"
  FAKE_ENABLED="happier-server happier-daemon.service"
  FAKE_ACTIVE="happier-server happier-daemon.service"
  run_update
  assert_ok "enabled unit refreshed with autostart" grep -q '^daemon_service 1$' "${LOG}"
  assert_ok "running daemon restarted via systemd" grep -q '^restart happier-daemon.service$' "${LOG}"
  assert_fail "never via the root CLI" grep -q '^cli daemon' "${LOG}"
}

test_server_only_has_no_daemon_step() {
  reset
  make_cli
  run_update
  assert_fail "no daemon unit -> no service install" grep -q '^daemon_service' "${LOG}"
}

test_missing_cli_is_reinstalled() {
  reset
  run_update
  assert_ok "missing CLI reinstalled by the bootstrap" grep -q '^install_happier_cli stable$' "${LOG}"
  assert_ok "then the relay is reinstalled with it" has_relay_line
}

test_bootstrap_failure_keeps_existing_cli() {
  reset
  make_cli
  FAKE_BOOTSTRAP_BROKEN=1
  assert_ok "update still exits 0" run_update
  assert_ok "warned" grep -q 'CLI update failed' "${LOG}"
  assert_ok "relay still reinstalled with the existing CLI" has_relay_line
}

test_no_cli_at_all_fails() {
  reset
  FAKE_BOOTSTRAP_BROKEN=1
  local rc=0
  run_update || rc=$?
  assert_eq "${rc}" "1" "no CLI after the bootstrap -> exit 1"
}

test_relay_failure_is_not_fatal() {
  reset
  make_cli
  FAKE_RELAY_RC=3
  assert_ok "update still exits 0" run_update
  assert_ok "warned with the rc" grep -q 'Relay host reinstall failed (rc=3)' "${LOG}"
  assert_ok "relay restored/restarted anyway" grep -q '^restart happier-server$' "${LOG}"
}

test_from_source_prints_guidance() {
  reset
  FAKE_CHANNEL=""
  local hb="${SB}/hstack"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${hb}"
  chmod +x "${hb}"
  local out rc=0
  out="$(HAPPIER_STACK_DEFAULT_BIN="${hb}" HAPPIER_STACK_DEFAULT_HOME="${SB}/stack" bash -c "
    $(declare -f update_script resolve_hstack_layout msg_warn msg_ok msg_error header_info check_container_storage check_container_resources detect_installed_channel)
    APP=Happier LOG='${LOG}' FAKE_CHANNEL=''
    sudo() { return 1; }
    update_script
  " 2>&1)" || rc=$?
  assert_eq "${rc}" "0" "from_source branch exits 0"
  assert_ok "shows the manual steps" grep -q 'git pull --ff-only' <<<"${out}"
  assert_fail "never touches a relay" grep -q '^cli ' "${LOG}"
}

test_nothing_installed_fails() {
  reset
  FAKE_CHANNEL=""
  local rc=0
  (HAPPIER_STACK_DEFAULT_BIN="${SB}/missing" update_script) >/dev/null 2>&1 || rc=$?
  assert_eq "${rc}" "1" "no installation -> exit 1"
}

run_tests
