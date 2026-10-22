#!/usr/bin/env bash
# D2: detect_installed_channel priority (stable > preview > dev). This is the
# update_script channel-detection logic, extracted into a testable helper in
# happier-common.func (previously un-extractable inside the `function` update_script).
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091 # test-local helper, resolved at runtime
source ./lib.sh

msg_warn() { :; }
msg_error() { echo "ERR: $*" >&2; }
msg_info() { :; }
msg_ok() { :; }
# shellcheck disable=SC1091 # unit under test, resolved at runtime
source ../../misc/happier-common.func

SB="$(mktemp -d)"
trap 'rm -rf "${SB}"' EXIT

# Point channel state paths into the sandbox. Top-level override (invoked
# indirectly by detect_installed_channel), so not flagged SC2329. This file only
# tests the detector, so clobbering the real path resolver here is fine.
channel_state_path() { printf '%s/%s.json' "${SB}" "$1"; }

clear_states() { rm -f "${SB}/stable.json" "${SB}/preview.json" "${SB}/dev.json"; }

test_none_present_returns_nonzero() {
  clear_states
  assert_fail "no state file -> returns non-zero" detect_installed_channel
  assert_eq "$(detect_installed_channel || true)" "" "no state file -> prints nothing"
}

test_dev_only() {
  clear_states
  : >"${SB}/dev.json"
  assert_eq "$(detect_installed_channel)" "dev" "dev state alone -> dev"
}

test_preview_beats_dev() {
  clear_states
  : >"${SB}/preview.json"
  : >"${SB}/dev.json"
  assert_eq "$(detect_installed_channel)" "preview" "preview outranks dev"
}

test_stable_beats_all() {
  clear_states
  : >"${SB}/stable.json"
  : >"${SB}/preview.json"
  : >"${SB}/dev.json"
  assert_eq "$(detect_installed_channel)" "stable" "stable outranks preview and dev"
}

# Review #1: systemd 257 exits 1 from `list-unit-files` when nothing matches. Under
# the engine's `set -Eeo pipefail` + ERR trap that must not abort the caller.
test_find_daemon_unit_survives_no_match_under_errexit() {
  local out rc=0
  out="$(bash -c '
    set -Eeo pipefail
    trap "echo TRAPPED; exit 99" ERR
    msg_warn() { :; }
    source ../../misc/happier-common.func
    systemctl() { return 1; }
    u="$(find_happier_daemon_unit)"
    echo "unit=[${u}]"
  ' 2>&1)" || rc=$?
  assert_eq "${rc}" "0" "no abort"
  assert_eq "${out}" "unit=[]" "empty unit, no ERR trap"
}

run_tests
