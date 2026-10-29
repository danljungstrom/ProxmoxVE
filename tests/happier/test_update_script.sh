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
SB="$(mktemp -d)"
trap 'rm -rf "${SB}"' EXIT
LOG="${SB}/log"
# Keep the real shared logic, mapping only absolute filesystem roots into an
# isolated fixture. This avoids writing system paths or mocking domain helpers.
eval "$(sed -e "s|/opt/happier|${SB}/opt/happier|g" \
  -e "s|/etc/happier|${SB}/etc/happier|g" \
  -e "s|/home/happier|${SB}/home/happier|g" \
  -e "s|/usr/local/bin|${SB}/usr/local/bin|g" ../../misc/happier-common.func)"
eval "$(extract_function "${CT_SH}" update_script)"
# shellcheck disable=SC2034 # read by the extracted update_script
APP="Happier"
# shellcheck disable=SC2034 # consumed by the real functions loaded with eval
STD=""
# shellcheck disable=SC2034 # consumed by the real functions loaded with eval
HAPPIER_HOME="${SB}/home/happier"
export LOG

# --- stubs (top-level so they are not flagged as unreachable) -----------------
header_info() { :; }
check_container_storage() { :; }
check_container_resources() { :; }
command() {
  if [[ "$1" == "-v" && ( "$2" == "happier" || "$2" == "hprev" || "$2" == "hdev" ) ]]; then
    [[ -x "${SB}/usr/local/bin/$2" ]] && printf '%s' "${SB}/usr/local/bin/$2"
    return
  fi
  builtin command "$@"
}
chown() { :; }
sudo() { return 1; }
# The download is the network boundary. The downloaded bootstrap installs a fake
# external CLI through the same directories/environment as the official one.
curl() {
  [[ -n "${FAKE_BOOTSTRAP_BROKEN:-}" ]] && return 22
  local dest=""
  while (($#)); do
    if [[ "$1" == "-o" ]]; then dest="$2"; break; fi
    shift
  done
  cat >"${dest}" <<'BOOTSTRAP'
#!/usr/bin/env bash
printf 'bootstrap %s\n' "$2" >>"${LOG}"
case "$2" in stable) name=happier ;; preview) name=hprev ;; dev) name=hdev ;; esac
mkdir -p "${HAPPIER_INSTALL_DIR}" "${HAPPIER_BIN_DIR}"
cp "${CLI_FIXTURE}" "${HAPPIER_BIN_DIR}/${name}"
chmod +x "${HAPPIER_BIN_DIR}/${name}"
BOOTSTRAP
}
# systemctl: is-enabled/is-active answer from FAKE_ENABLED/FAKE_ACTIVE (unit
# names), everything else is logged.
systemctl() {
  case "$1" in
    is-enabled) [[ " ${FAKE_ENABLED} " == *" ${3} "* ]] ;;
    is-active) [[ " ${FAKE_ACTIVE} " == *" ${3} "* ]] ;;
    list-unit-files | list-units) [[ -z "${FAKE_DAEMON_UNIT}" ]] || printf '%s enabled\n' "${FAKE_DAEMON_UNIT}" ;;
    *)
      echo "systemctl $*" >>"${LOG}"
      [[ "${FAKE_SYSTEMCTL_FAILURE:-}" != "$1 $2" ]]
      ;;
  esac
}

make_cli() { # fake CLI: logs its argv, fails `relay host install` when FAKE_RELAY_RC set
  mkdir -p "${SB}/usr/local/bin"
  cat >"${CLI_FIXTURE}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "cli $*" >>"${LOG}"
case " $* " in
  *' server current '*)
    printf '%s' '{"v":1,"ok":true,"kind":"server_current","data":{"active":{"id":"proxmox-id"}}}'
    ;;
  *' server list '*)
    printf '%s' '{"v":1,"ok":true,"kind":"server_list","data":{"profiles":[{"id":"proxmox-id","name":"proxmox"}]}}'
    ;;
  *' service list '*)
    if [[ -n "${FAKE_DAEMON_UNIT:-}" ]]; then
      printf '{"entries":[{"installed":true,"platform":"linux","mode":"system","happierHomeDir":"%s","releaseChannel":"stable","targetMode":"pinned","serverId":"proxmox-id","activeServerId":"proxmox-id","path":"/etc/systemd/system/%s"}]}' \
        "${HAPPIER_HOME_DIR}" "${FAKE_DAEMON_UNIT}"
    else
      printf '%s' '{"entries":[]}'
    fi
    ;;
  *' service paths '*)
    printf '{"ok":true,"platform":"linux","paths":{"unitName":"%s","unitPath":"/etc/systemd/system/%s"}}' \
      "${FAKE_DAEMON_UNIT:-happier-daemon.proxmox-id.service}" "${FAKE_DAEMON_UNIT:-happier-daemon.proxmox-id.service}"
    ;;
  *' service install '*) exit "${FAKE_DAEMON_RC:-0}" ;;
  *' relay host install '*) exit "${FAKE_RELAY_RC:-0}" ;;
esac
exit 0
EOF
  chmod +x "${CLI_FIXTURE}"
  cp "${CLI_FIXTURE}" "${SB}/usr/local/bin/happier"
}

reset() {
  rm -rf "${SB:?}/opt" "${SB:?}/etc" "${SB:?}/usr" "${SB:?}/home"
  : >"${LOG}"
  local state
  state="$(channel_state_path stable)"
  mkdir -p "$(dirname "${state}")"
  : >"${state}"
  CLI_FIXTURE="${SB}/cli-fixture"
  export CLI_FIXTURE
  make_cli
  rm -f "${SB}/usr/local/bin/happier"
  FAKE_DAEMON_UNIT=""
  FAKE_ENABLED="happier-server"
  FAKE_ACTIVE="happier-server"
  FAKE_BOOTSTRAP_BROKEN=""
  FAKE_SYSTEMCTL_FAILURE=""
  FAKE_DAEMON_RC=0
  unset FAKE_RELAY_RC
  export FAKE_RELAY_RC FAKE_DAEMON_UNIT FAKE_DAEMON_RC LOG
}

run_update() { (update_script) >/dev/null 2>&1; }
relay_line() { grep '^cli relay host install' "${LOG}"; }
has_relay_line() { relay_line >/dev/null; }

# --- tests ------------------------------------------------------------------

test_relay_reinstall_args() {
  reset
  make_cli
  local env_path
  env_path="$(channel_config_env_path stable)"
  mkdir -p "$(dirname "${env_path}")"
  cat >"${env_path}" <<'EOF'
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
  assert_ok "CLI updated via the bootstrap on the installed channel" grep -q '^bootstrap stable$' "${LOG}"
  assert_fail "never via root self update" grep -q '^cli self update' "${LOG}"
}

test_preview_channel_args() {
  reset
  make_cli
  rm -f "$(channel_state_path stable)"
  mkdir -p "$(dirname "$(channel_state_path preview)")"
  : >"$(channel_state_path preview)"
  FAKE_ENABLED="happier-server-preview"
  FAKE_ACTIVE="happier-server-preview"
  run_update
  assert_eq "$(relay_line)" "cli relay host install --mode system --channel preview --yes" "channel threaded through"
  assert_ok "preview relay restarted" grep -q '^systemctl restart happier-server-preview$' "${LOG}"
}

test_autostart_off_is_restored() {
  reset
  make_cli
  FAKE_ENABLED=""
  FAKE_ACTIVE=""
  run_update
  assert_ok "relay disabled again" grep -q '^systemctl disable -q happier-server$' "${LOG}"
  assert_ok "relay stopped again" grep -q '^systemctl stop happier-server$' "${LOG}"
  assert_fail "relay not restarted" grep -q '^systemctl restart happier-server$' "${LOG}"
}

test_enabled_but_stopped_stays_stopped() {
  reset
  make_cli
  FAKE_ACTIVE=""
  run_update
  assert_fail "not disabled" grep -q 'disable' "${LOG}"
  assert_ok "autostart stays enabled" grep -q '^systemctl enable -q happier-server$' "${LOG}"
  assert_ok "stopped again" grep -q '^systemctl stop happier-server$' "${LOG}"
}

test_daemon_unit_refreshed_and_state_kept() {
  reset
  make_cli
  FAKE_DAEMON_UNIT="happier-daemon.proxmox-id.service"
  run_update
  assert_ok "unit refreshed with --no-autostart semantics (was disabled)" grep -q '^cli .*service install .*--no-autostart' "${LOG}"
  assert_fail "inactive daemon not restarted" grep -q '^systemctl restart happier-daemon.proxmox-id.service$' "${LOG}"
  assert_ok "inactive daemon stopped again" grep -q '^systemctl stop happier-daemon.proxmox-id.service$' "${LOG}"
  reset
  make_cli
  FAKE_DAEMON_UNIT="happier-daemon.proxmox-id.service"
  FAKE_ENABLED="happier-server happier-daemon.proxmox-id.service"
  FAKE_ACTIVE="happier-server happier-daemon.proxmox-id.service"
  run_update
  assert_ok "enabled unit refreshed" grep -q '^cli .*service install ' "${LOG}"
  assert_fail "autostart retained" grep -q '^cli .*service install .*--no-autostart' "${LOG}"
  assert_ok "running daemon restarted via systemd" grep -q '^systemctl restart happier-daemon.proxmox-id.service$' "${LOG}"
  assert_fail "never via the root CLI" grep -q '^cli daemon' "${LOG}"
}

test_server_only_has_no_daemon_step() {
  reset
  make_cli
  run_update
  assert_fail "no daemon unit -> no service install" grep -q '^cli .*service install ' "${LOG}"
}

test_missing_cli_is_reinstalled() {
  reset
  run_update
  assert_ok "missing CLI reinstalled by the bootstrap" grep -q '^bootstrap stable$' "${LOG}"
  assert_ok "then the relay is reinstalled with it" has_relay_line
}

test_bootstrap_failure_preserves_existing_installation() {
  reset
  make_cli
  local legacy_cli="${SB}/opt/happier/cli/bin/happier"
  mkdir -p "$(dirname "${legacy_cli}")"
  mv "${SB}/usr/local/bin/happier" "${legacy_cli}"
  FAKE_BOOTSTRAP_BROKEN=1
  assert_fail "failed CLI update fails the update" run_update
  assert_ok "warned" grep -q 'CLI update failed' "${LOG}"
  assert_fail "relay is untouched when CLI migration fails" has_relay_line
  assert_ok "legacy CLI survives the failed migration" test -x "${legacy_cli}"
  assert_fail "services are untouched after failed CLI migration" grep -q '^systemctl' "${LOG}"
}

test_no_cli_at_all_fails() {
  reset
  FAKE_BOOTSTRAP_BROKEN=1
  local rc=0
  run_update || rc=$?
  assert_eq "${rc}" "1" "no CLI after the bootstrap -> exit 1"
}

test_relay_failure_recovers_before_returning_failure() {
  reset
  make_cli
  FAKE_RELAY_RC=3
  assert_fail "relay failure is reflected in the update status" run_update
  assert_ok "warned with the rc" grep -q 'Relay host reinstall failed (rc=3)' "${LOG}"
  assert_ok "relay restored/restarted anyway" grep -q '^systemctl restart happier-server$' "${LOG}"
}

test_from_source_prints_guidance() {
  reset
  rm -f "$(channel_state_path stable)"
  local hb="${SB}/hstack"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${hb}"
  chmod +x "${hb}"
  local out rc=0
  out="$(HAPPIER_STACK_DEFAULT_BIN="${hb}" HAPPIER_STACK_DEFAULT_HOME="${SB}/stack" update_script 2>&1)" || rc=$?
  assert_eq "${rc}" "0" "from_source branch exits 0"
  assert_ok "shows the manual steps" grep -q 'git pull --ff-only' <<<"${out}"
  assert_fail "never touches a relay" grep -q '^cli ' "${LOG}"
}

test_nothing_installed_fails() {
  reset
  rm -f "$(channel_state_path stable)"
  local rc=0
  (HAPPIER_STACK_DEFAULT_BIN="${SB}/missing" update_script) >/dev/null 2>&1 || rc=$?
  assert_eq "${rc}" "1" "no installation -> exit 1"
}

test_restart_failure_recovers_daemon_before_failing() {
  reset
  FAKE_DAEMON_UNIT="happier-daemon.proxmox-id.service"
  FAKE_ACTIVE="happier-server happier-daemon.proxmox-id.service"
  FAKE_ENABLED="happier-server happier-daemon.proxmox-id.service"
  FAKE_SYSTEMCTL_FAILURE="restart happier-server"
  assert_fail "restart failure fails the update" run_update
  assert_ok "daemon refresh still runs after relay restart failure" grep -q '^cli .*service install ' "${LOG}"
  assert_ok "daemon restart still runs after relay restart failure" grep -q '^systemctl restart happier-daemon.proxmox-id.service$' "${LOG}"
  assert_ok "restart failure is visible" grep -q '^WARN:' "${LOG}"
}

test_stopped_state_failure_is_reported() {
  reset
  FAKE_ACTIVE=""
  FAKE_SYSTEMCTL_FAILURE="stop happier-server"
  assert_fail "failed stopped-state restoration fails the update" run_update
  assert_ok "restoration failure is visible" grep -q '^WARN:' "${LOG}"
}

test_daemon_refresh_failure_restores_state_before_failing() {
  reset
  FAKE_DAEMON_UNIT="happier-daemon.proxmox-id.service"
  FAKE_DAEMON_RC=3
  assert_fail "incomplete daemon refresh fails the update" run_update
  assert_ok "previous disabled state is restored" grep -q '^systemctl disable -q happier-daemon.proxmox-id.service$' "${LOG}"
  assert_ok "previous stopped state is restored" grep -q '^systemctl stop happier-daemon.proxmox-id.service$' "${LOG}"
  assert_ok "refresh failure is visible" grep -q '^WARN:.*rc=3' "${LOG}"
}

run_tests
