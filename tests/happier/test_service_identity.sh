#!/usr/bin/env bash
# CLI JSON fixtures use the released cli-v0.2.17 service/server contract.
# Only the external CLI and systemctl boundaries are simulated.
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091
source ./lib.sh
msg_warn() { printf 'WARN: %s\n' "$*" >&2; }
msg_error() { printf 'ERROR: %s\n' "$*" >&2; }
# shellcheck disable=SC1091
source ../../misc/happier-common.func
SB="$(mktemp -d)"
trap 'rm -rf "${SB}"' EXIT
HAPPIER_HOME="${SB}/home"
mkdir -p "${HAPPIER_HOME}/.happier"
export FIXTURE_DIR="${SB}" CLI_LOG="${SB}/cli.log"
cat >"${SB}/cli" <<'CLI'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CLI_LOG}"
case "$*" in
  *'server current --json'*)
    [[ "${FAKE_PROFILE_PRESENT:-1}" == 1 ]] || exit 1
    printf '%s\n' '{"v":1,"ok":true,"kind":"server_current","data":{"active":{"id":"proxmox-id"}}}'
    ;;
  *'server list --json'*)
    if [[ "${FAKE_PROFILE_PRESENT:-1}" == 1 ]]; then
      printf '%s\n' '{"v":1,"ok":true,"kind":"server_list","data":{"profiles":[{"id":"proxmox-id","name":"proxmox"}]}}'
    else
      printf '%s\n' '{"v":1,"ok":true,"kind":"server_list","data":{"profiles":[]}}'
    fi
    ;;
  *'service list '*) cat "${FIXTURE_DIR}/inventory.json" ;;
  *'service paths '*)
    case "$*" in *'--instance'*) unit=happier-daemon.proxmox-id.service ;; *) unit=happier-daemon.default.service ;; esac
    printf '{"ok":true,"platform":"linux","paths":{"unitName":"%s","unitPath":"/etc/systemd/system/%s"}}\n' "${unit}" "${unit}"
    ;;
  *'service install '*) exit "${FAKE_INSTALL_RC:-0}" ;;
  *) exit 2 ;;
esac
CLI
chmod +x "${SB}/cli"
systemctl() { return 5; }
# Ownership changes are an OS boundary; never touch an actual user directory.
chown() { :; }

inventory() {
  local target_mode="$1" id="$2" home="${3:-${HAPPIER_HOME}/.happier}"
  jq -n --arg mode "${target_mode}" --arg id "${id}" --arg home "${home}" \
    '{installed:true,platform:"linux",mode:"system",happierHomeDir:$home,releaseChannel:"stable",targetMode:$mode,serverId:$id,activeServerId:$id,path:("/etc/systemd/system/happier-daemon."+$id+".service")}'
}
reset() { : >"${CLI_LOG}"; export FAKE_PROFILE_PRESENT=1; printf '{"entries":[]}\n' >"${SB}/inventory.json"; }

test_fresh_service_uses_cli_identity() {
  reset
  assert_ok "resolve empty inventory" resolve_happier_daemon_service "${SB}/cli" stable || return
  assert_eq "${HAPPIER_DAEMON_INSTALLED}" 0 "no service installed"
  assert_eq "${HAPPIER_DAEMON_UNIT}" '' "no service selected"
}

test_unrelated_service_does_not_receive_wiring() {
  reset
  { inventory pinned cloud; inventory pinned proxmox-id; inventory pinned proxmox-id /other/home; } | jq -s '{entries:.}' >"${SB}/inventory.json"
  assert_ok "resolve matching pinned service" resolve_happier_daemon_service "${SB}/cli" stable || return
  assert_eq "${HAPPIER_DAEMON_INSTALLED}" 1 "selected installed entry"
  assert_eq "${HAPPIER_DAEMON_UNIT}" happier-daemon.proxmox-id.service "ignores earlier unrelated unit"
}

test_default_following_service_keeps_its_identity() {
  reset
  inventory default-following default | jq -s '{entries:.}' >"${SB}/inventory.json"
  assert_ok "retain default service" resolve_happier_daemon_service "${SB}/cli" stable || return
  assert_eq "${HAPPIER_DAEMON_UNIT}" happier-daemon.default.service "existing identity"
  assert_eq "${#HAPPIER_DAEMON_SERVICE_ARGS[@]}" 0 "no forced conversion to pinned"
}

test_ambiguous_inventory_fails_without_choosing() {
  reset
  { inventory default-following default; inventory pinned proxmox-id; } | jq -s '{entries:.}' >"${SB}/inventory.json"
  assert_fail "ambiguous ownership fails" resolve_happier_daemon_service "${SB}/cli" stable
  assert_fail "no service mutation" grep -q 'service install' "${CLI_LOG}"
}

test_malformed_inventory_is_not_absence() {
  reset
  printf '{}\n' >"${SB}/inventory.json"
  assert_fail "missing entries rejected" resolve_happier_daemon_service "${SB}/cli" stable
}

test_server_only_survives_no_match_under_errexit() {
  reset
  local rc=0
  bash -c 'set -Eeuo pipefail; source ../../misc/happier-common.func; resolve_happier_daemon_service "$1" stable; [[ "$HAPPIER_DAEMON_INSTALLED" == 0 ]]' _ "${SB}/cli" || rc=$?
  assert_eq "${rc}" 0 "empty inventory is normal with the engine error trap"
  assert_fail "server_only needs no Proxmox profile" grep -q 'server current' "${CLI_LOG}"
}

test_server_only_ignores_unrelated_pinned_services() {
  reset
  export FAKE_PROFILE_PRESENT=0
  inventory pinned cloud | jq -s '{entries:.}' >"${SB}/inventory.json"
  assert_ok "an unrelated pinned daemon needs no Proxmox profile" resolve_happier_daemon_service "${SB}/cli" stable || return
  assert_eq "${HAPPIER_DAEMON_INSTALLED}" 0 "no Proxmox daemon"
  assert_fail "does not select a missing profile" grep -q 'server current' "${CLI_LOG}"
}

test_restart_failure_is_observable() {
  local rc=0 out
  out="$(restart_happier_unit happier-daemon.proxmox-id.service 2>&1)" || rc=$?
  assert_eq "${rc}" 5 "systemctl status preserved"
  assert_ok "warning names affected unit" grep -q 'happier-daemon.proxmox-id.service' <<<"${out}"
}

test_install_refresh_preserves_pinned_identity() {
  reset
  inventory pinned proxmox-id | jq -s '{entries:.}' >"${SB}/inventory.json"
  assert_ok "refresh installed pinned service" happier_install_daemon_service "${SB}/cli" 0 stable
  assert_ok "CLI receives existing instance and channel" grep -q 'service install .*--instance proxmox-id --ring stable' "${CLI_LOG}"
}

run_tests
