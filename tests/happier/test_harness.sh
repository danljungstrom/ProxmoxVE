#!/usr/bin/env bash
# Exercise the public assertion/runner output and status through fresh shells.
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091 # test-local helper, resolved at runtime
source ./lib.sh

SB="$(mktemp -d)"
trap 'rm -rf "${SB}"' EXIT
mkdir -p "${SB}/bin"
# The engine's network dependency is the only mocked boundary.
cat >"${SB}/bin/curl" <<'CURL'
#!/usr/bin/env bash
exit 22
CURL
chmod +x "${SB}/bin/curl"

in_harness() {
  bash -c 'source ./lib.sh; '"$1"
}

test_assert_ok_reports_original_failure_status() {
  local out rc=0
  out="$(in_harness 'assert_ok fixture bash -c "exit 7"')" || rc=$?
  assert_eq "${rc}" 1 "assertion fails"
  assert_ok "original command status is retained" grep -q 'got rc=7$' <<<"${out}"
}

test_runner_rejects_unhandled_return_status_and_continues() {
  local out rc=0
  out="$(in_harness '
    test_a() { return 9; }
    test_z() { echo next-test-ran; }
    run_tests
  ')" || rc=$?
  assert_eq "${rc}" 1 "unhandled test failure fails the suite"
  assert_ok "failed test reports its status" grep -q '^not ok - test_a: .*9' <<<"${out}"
  assert_ok "later tests still run" grep -qx 'next-test-ran' <<<"${out}"
  assert_ok "summary counts the failed test" grep -qx '# 2 tests, 1 failed, 0 skipped' <<<"${out}"
  assert_fail "failed test has no pass line" grep -qx 'ok - test_a' <<<"${out}"
}

test_runner_preserves_assertion_and_skip_accounting() {
  local out rc=0
  out="$(in_harness '
    test_a() { assert_eq actual expected fixture; }
    test_b() { skip unavailable; }
    run_tests
  ')" || rc=$?
  assert_eq "${rc}" 1 "assertion failure fails the suite"
  assert_ok "failed assertion is counted once" grep -qx '# 2 tests, 1 failed, 1 skipped' <<<"${out}"
  assert_eq "$(grep -c '^ok - test_b' <<<"${out}")" 1 "skip has one result line"
}

offline_engine_contract() {
  PATH="${SB}/bin:${PATH}" bash -c '
    source ./lib.sh
    eval "$(extract_function ./test_skin.sh test_engine_contract_at_pinned_ref)"
    SB="$1"
    run_tests
  ' _ "${SB}"
}

test_engine_download_failure_fails_ci() {
  local out rc=0
  out="$(CI=true offline_engine_contract)" || rc=$?
  assert_eq "${rc}" 1 "CI cannot skip a missing pinned engine"
  assert_ok "download failure is reported" grep -q '^not ok - test_engine_contract_at_pinned_ref:' <<<"${out}"
  assert_ok "CI did not count a skip" grep -qx '# 1 tests, 1 failed, 0 skipped' <<<"${out}"
}

test_engine_download_failure_can_skip_local_offline_run() {
  local out rc=0
  out="$(CI='' offline_engine_contract)" || rc=$?
  assert_eq "${rc}" 0 "local offline engine check can skip"
  assert_ok "local skip is counted" grep -qx '# 1 tests, 0 failed, 1 skipped' <<<"${out}"
}

run_tests
