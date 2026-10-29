#!/usr/bin/env bash
# Exercise the pre-engine updater rewrite against isolated filesystem/process boundaries.
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091
source ./lib.sh
SB="$(mktemp -d)"
trap 'rm -rf "${SB}"' EXIT
REWRITE="$(sed '/^_cs_boot=/,$d' ../../ct/happier.sh | sed "s|/usr/bin|${SB}/bin|g")"

reset() {
  rm -rf "${SB:?}/bin" "${SB}/continued" "${SB}/effect"
  mkdir "${SB}/bin"
  printf 'INSTALLER_REPO legacy updater\n' >"${SB}/bin/update"
}

# shellcheck disable=SC2329,SC2059 # eval invokes OS shims; printf forwards the caller's format verbatim
rewrite() {
  (
    # OS failures are injected beneath the real top-level rewrite logic.
    command() {
      if [[ "$1" == -v && "$2" == pveversion ]]; then return 1; fi
      builtin command "$@"
    }
    mktemp() { if [[ "${FAIL_STAGE:-}" == mktemp ]]; then return 1; fi; command mktemp "$@"; }
    printf() { if [[ "${FAIL_STAGE:-}" == printf ]]; then return 1; fi; builtin printf "$@"; }
    chmod() { if [[ "${FAIL_STAGE:-}" == chmod ]]; then return 1; fi; command chmod "$@"; }
    mv() { if [[ "${FAIL_STAGE:-}" == mv ]]; then return 1; fi; command mv "$@"; }
    eval "${REWRITE}"
    : >"${SB}/continued"
  )
}

test_failed_rewrite_preserves_entrypoint_and_stops_before_engine() {
  local stage out rc
  for stage in mktemp printf chmod mv; do
    reset
    rc=0
    out="$(FAIL_STAGE="${stage}" rewrite 2>&1)" || rc=$?
    assert_fail "${stage}: rewrite failure is returned" test "${rc}" -eq 0
    assert_eq "$(cat "${SB}/bin/update")" 'INSTALLER_REPO legacy updater' "${stage}: existing updater survives"
    assert_eq "$(find "${SB}/bin" -name '.update.*' | wc -l)" 0 "${stage}: no temporary updater remains"
    assert_fail "${stage}: engine migration cannot continue" test -e "${SB}/continued"
    assert_ok "${stage}: failure is visible" test -n "${out}"
  done
}

test_successful_rewrite_replaces_entrypoint() {
  reset
  assert_ok "rewrite succeeds" rewrite
  assert_ok "replacement is executable" test -x "${SB}/bin/update"
  assert_fail "legacy placeholders removed" grep -q INSTALLER_REPO "${SB}/bin/update"
  assert_eq "$(find "${SB}/bin" -name '.update.*' | wc -l)" 0 "temporary updater moved away"
  assert_ok "engine migration may continue" test -e "${SB}/continued"
}

test_generated_updater_preserves_fetch_and_payload_status() {
  reset
  assert_ok "write transitional updater" rewrite
  # The network boundary can fail before returning data or after a partial body.
  cat >"${SB}/bin/curl" <<'CURL'
#!/usr/bin/env bash
if [[ "${WITH_BODY}" == 1 ]]; then
  printf '%s\n' ': >"${UPDATE_EFFECT}"' 'exit 7'
fi
exit "${FETCH_RC}"
CURL
  chmod +x "${SB}/bin/curl"
  local body rc
  for body in 0 1; do
    rc=0
    PATH="${SB}/bin:${PATH}" FETCH_RC=22 WITH_BODY="${body}" UPDATE_EFFECT="${SB}/effect" bash "${SB}/bin/update" || rc=$?
    assert_eq "${rc}" 22 "failed fetch status is preserved (body=${body})"
    assert_fail "failed fetch never executes a partial response" test -e "${SB}/effect"
  done
  rc=0
  PATH="${SB}/bin:${PATH}" FETCH_RC=0 WITH_BODY=1 UPDATE_EFFECT="${SB}/effect" bash "${SB}/bin/update" || rc=$?
  assert_eq "${rc}" 7 "downloaded script status is preserved"
  assert_ok "successful fetch executes its response" test -e "${SB}/effect"
}

run_tests
