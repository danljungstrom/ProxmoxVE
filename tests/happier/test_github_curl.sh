#!/usr/bin/env bash
# D7: happier_github_curl auth tiers (token -> Bearer --config file vs anonymous
# headers) + net opts, and the resolve_happier_release_json_for_tags tag-fallback
# buffering (A8). `curl` is stubbed to record args and dump the resolved --config.
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091 # test-local helper, resolved at runtime
source ./lib.sh

msg_warn() { :; }
msg_error() { echo "ERR: $*" >&2; }
msg_info() { :; }
msg_ok() { :; }
export HAPPIER_MINISIGN_PUBKEY="test-key-placeholder"
# shellcheck disable=SC1091 # unit under test, resolved at runtime
source ../../misc/happier-common.func

SB="$(mktemp -d)"
trap 'rm -rf "${SB}"' EXIT
ARGS="${SB}/curl.args"
CONFIG_DUMP="${SB}/curl.config"

# Top-level curl stub (invoked indirectly by the unit under test, so not flagged
# SC2329): records the arg line, dumps any --config file, and emits PAYLOAD to the
# -o destination or stdout.
curl() {
  printf '%s\n' "$*" >>"${ARGS}"
  local a prev=""
  for a in "$@"; do
    [[ "${prev}" == "--config" ]] && cat "${a}" >"${CONFIG_DUMP}" 2>/dev/null
    prev="${a}"
  done
  local dest=""
  prev=""
  for a in "$@"; do
    [[ "${prev}" == "-o" ]] && dest="${a}"
    prev="${a}"
  done
  if [[ -n "${dest}" ]]; then printf 'PAYLOAD' >"${dest}"; else printf 'PAYLOAD'; fi
  return 0
}

test_anon_headers_and_net_opts() {
  : >"${ARGS}"
  unset HAPPIER_GITHUB_TOKEN
  local out
  out="$(happier_github_curl stdout "https://api.github.com/x")"
  assert_eq "${out}" "PAYLOAD" "stdout payload returned"
  assert_ok "has --max-time" grep -q -- "--max-time" "${ARGS}"
  assert_ok "has --retry 3" grep -q -- "--retry 3" "${ARGS}"
  assert_ok "anon Accept header present" grep -q "Accept: application/vnd.github" "${ARGS}"
  assert_fail "anon uses no --config" grep -q -- "--config" "${ARGS}"
}

test_token_uses_bearer_config() {
  : >"${ARGS}"
  : >"${CONFIG_DUMP}"
  export HAPPIER_GITHUB_TOKEN="ghp_secrettoken123"
  happier_github_curl stdout "https://api.github.com/x" >/dev/null
  unset HAPPIER_GITHUB_TOKEN
  assert_ok "token path uses --config" grep -q -- "--config" "${ARGS}"
  assert_ok "config carries the Bearer token" grep -q "Authorization: Bearer ghp_secrettoken123" "${CONFIG_DUMP}"
}

test_file_mode_requires_destination() {
  assert_fail "file mode without destination -> non-zero" happier_github_curl file "https://x"
}

test_file_mode_writes_destination() {
  local d="${SB}/out.bin"
  assert_ok "file mode returns 0" happier_github_curl file "https://x" "${d}"
  assert_eq "$(cat "${d}")" "PAYLOAD" "payload written to the destination file"
}

test_tag_fallback_second_tag() {
  # A8: the resolver must try tags in order and return the first that succeeds,
  # buffered so a failed earlier attempt does not corrupt the emitted JSON.
  local out
  out="$(
    # shellcheck disable=SC2329 # invoked indirectly by resolve_happier_release_json_for_tags
    happier_github_curl() {
      [[ "$2" == *ui-web-stable* ]] && {
        printf '{"tag":"stable"}'
        return 0
      }
      return 1
    }
    resolve_happier_release_json_for_tags "owner/repo" ui-web-preview ui-web-stable
  )"
  assert_eq "${out}" '{"tag":"stable"}' "falls through preview to stable, clean JSON"
}

test_tag_fallback_all_fail() {
  local rc=0
  (
    # shellcheck disable=SC2329 # invoked indirectly
    happier_github_curl() { return 1; }
    resolve_happier_release_json_for_tags "owner/repo" a b c
  ) >/dev/null 2>&1 || rc=$?
  assert_eq "${rc}" "1" "all tags failing -> return 1"
}

run_tests
