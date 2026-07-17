#!/usr/bin/env bash
# D6: enroll_tailscale_node outcome classification. A fake `tailscale` binary and
# fast waiter stubs drive each branch (no key / invalid key / timeout / online /
# offline-needs-login); assertions check the epilogue flags it sets.
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091 # test-local helper, resolved at runtime
source ./lib.sh

msg_warn() { :; }
msg_error() { echo "ERR: $*" >&2; }
msg_info() { :; }
msg_ok() { :; }

INSTALL_SH="../../install/happier-install.sh"
eval "$(extract_function "${INSTALL_SH}" tailscale_status_json_field)"
eval "$(extract_function "${INSTALL_SH}" enroll_tailscale_node)"

# Fast stand-ins for the systemd/online waiters (top-level; invoked indirectly by
# the extracted enroll function, so not flagged SC2329).
wait_for_systemd_active() { return 0; }
tailscale_wait_until_online() { [[ "${TS_ONLINE:-0}" == "1" ]]; }

SB="$(mktemp -d)"
trap 'rm -rf "${SB}"' EXIT
mkdir -p "${SB}/bin"
cat >"${SB}/bin/tailscale" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  set) exit 0 ;;
  up)
    case "${TS_SCENARIO:-ok}" in
      invalid) echo "invalid key provided" >&2; exit 1 ;;
      timeout) exit 124 ;;
      *) exit 0 ;;
    esac ;;
  ip) [[ "${TS_ONLINE:-0}" == "1" ]] && exit 0 || exit 1 ;;
  status) printf '%s' "${TS_STATUS_JSON:-}" ;;
esac
exit 0
FAKE
chmod +x "${SB}/bin/tailscale"
export PATH="${SB}/bin:${PATH}"

reset_flags() {
  # shellcheck disable=SC2034 # read by the eval'd enroll_tailscale_node
  TAILSCALE_AUTHKEY="tskey-abc"
  TAILSCALE_ENABLE_SERVE=0
  TAILSCALE_AUTH_INVALID=0
  TAILSCALE_NEEDS_LOGIN=0
  TAILSCALE_AUTH_URL=""
  TS_SCENARIO="ok"
  TS_ONLINE=0
  TS_STATUS_JSON='{}'
  # Export so the fake `tailscale` (a separate process) sees the scenario.
  export TS_SCENARIO TS_ONLINE TS_STATUS_JSON
}

test_no_authkey_is_noop() {
  reset_flags
  # shellcheck disable=SC2034 # read by the eval'd enroll_tailscale_node
  TAILSCALE_AUTHKEY=""
  enroll_tailscale_node
  assert_eq "${TAILSCALE_ENABLE_SERVE}" "0" "no key -> serve not enabled"
  assert_eq "${TAILSCALE_NEEDS_LOGIN}" "0" "no key -> no needs-login"
}

test_invalid_key() {
  reset_flags
  TS_SCENARIO="invalid"
  TS_STATUS_JSON='{"AuthURL":"https://login.example/x"}'
  enroll_tailscale_node
  assert_eq "${TAILSCALE_AUTH_INVALID}" "1" "invalid key -> AUTH_INVALID"
  assert_eq "${TAILSCALE_NEEDS_LOGIN}" "1" "invalid key -> NEEDS_LOGIN"
  assert_eq "${TAILSCALE_ENABLE_SERVE}" "0" "invalid key -> serve off"
}

test_timeout_needs_login() {
  reset_flags
  TS_SCENARIO="timeout"
  TS_STATUS_JSON='{"AuthURL":"https://login.example/y"}'
  enroll_tailscale_node
  assert_eq "${TAILSCALE_NEEDS_LOGIN}" "1" "timeout -> NEEDS_LOGIN"
  assert_eq "${TAILSCALE_AUTH_URL}" "https://login.example/y" "timeout -> AuthURL captured"
  assert_eq "${TAILSCALE_ENABLE_SERVE}" "0" "timeout -> serve off"
}

test_online_enables_serve() {
  reset_flags
  TS_SCENARIO="ok"
  TS_ONLINE=1
  enroll_tailscale_node
  assert_eq "${TAILSCALE_ENABLE_SERVE}" "1" "online -> serve enabled"
  assert_eq "${TAILSCALE_AUTH_INVALID}" "0" "online -> not invalid"
  assert_eq "${TAILSCALE_NEEDS_LOGIN}" "0" "online -> not needs-login"
}

test_offline_with_authurl_needs_login() {
  reset_flags
  TS_SCENARIO="ok"
  TS_ONLINE=0
  TS_STATUS_JSON='{"AuthURL":"https://login.example/z","BackendState":"NeedsLogin"}'
  enroll_tailscale_node
  assert_eq "${TAILSCALE_ENABLE_SERVE}" "0" "offline -> serve off"
  assert_eq "${TAILSCALE_NEEDS_LOGIN}" "1" "offline w/ AuthURL -> NEEDS_LOGIN"
  assert_eq "${TAILSCALE_AUTH_URL}" "https://login.example/z" "offline -> AuthURL captured"
}

run_tests
