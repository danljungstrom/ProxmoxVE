#!/usr/bin/env bash
# Package installation failures must propagate even when the caller checks the
# helper in an `if !` condition, which suspends Bash's errexit inside the helper.
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091 # test-local helper
source ./lib.sh

msg_error() { :; }
msg_warn() { printf 'WARN: %s\n' "$*"; }
eval "$(extract_function ../../install/happier-install.sh install_tailscale_pkg)"

SB="$(mktemp -d)"
trap 'rm -rf "${SB}"' EXIT
# shellcheck disable=SC2034 # read by the extracted production function
STD=""

# Genuine system boundaries only: downloads, privileged filesystem writes,
# package-manager operations and service activation. Temporary files stay real.
curl() {
  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == "-o" ]]; then
      printf 'downloaded\n' >"$2"
      return 0
    fi
    shift
  done
  return 1
}
install() {
  printf 'install %s\n' "${*: -1}" >>"${SB}/operations"
  [[ "${FAIL_STAGE}" != "repo" ]]
}
apt-get() {
  printf 'apt %s\n' "$1" >>"${SB}/operations"
  [[ "${FAIL_STAGE}" != "$1" ]] || return 42
}
systemctl() { printf 'service\n' >>"${SB}/operations"; }

test_failure_stops_package_setup_before_service_activation() {
  local stage rc
  for stage in repo install; do
    FAIL_STAGE="${stage}"
    : >"${SB}/operations"
    rc=0
    # Match the real caller: success/failure must be explicit inside the helper.
    if ! install_tailscale_pkg; then rc=1; fi
    assert_eq "${rc}" "1" "${stage} failure propagates"
    assert_fail "${stage} failure does not activate tailscaled" grep -q '^service$' "${SB}/operations"
    if [[ "${stage}" != "install" ]]; then
      assert_fail "${stage} failure prevents package installation" grep -q '^apt install$' "${SB}/operations"
    fi
  done
}

test_index_refresh_failure_warns_and_still_installs() {
  FAIL_STAGE="update"
  : >"${SB}/operations"
  local output rc=0
  output="$(install_tailscale_pkg)" || rc=$?
  assert_eq "${rc}" "0" "existing package index can still satisfy installation"
  assert_ok "index refresh failure is visible" grep -q '^WARN:' <<<"${output}"
  assert_ok "package installation was attempted" grep -q '^apt install$' "${SB}/operations"
  assert_ok "successfully installed service was activated" grep -q '^service$' "${SB}/operations"
}

test_success_installs_and_activates_tailscale() {
  FAIL_STAGE=""
  : >"${SB}/operations"
  assert_ok "package setup succeeds" install_tailscale_pkg
  assert_ok "package was installed" grep -q '^apt install$' "${SB}/operations"
  assert_ok "service was activated" grep -q '^service$' "${SB}/operations"
}

run_tests
