#!/usr/bin/env bash
# D13: retry_until attempt/timing logic (pure, extracted from the installer).
# The real `sleep` is shadowed by an instant counter so the assertions are fast
# and can check that no sleep happens after the final attempt (the P3 fix).
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091 # test-local helper, resolved at runtime
source ./lib.sh

INSTALL_SH="../../install/happier-install.sh"

eval "$(extract_function "${INSTALL_SH}" retry_until)"

# Instant, counted stand-in for the external `sleep` (top-level def shadows it for
# the eval'd retry_until). true/false are used as the probe so no nested callback
# functions are needed.
SLEEP_CALLS=0
sleep() { SLEEP_CALLS=$((SLEEP_CALLS + 1)); }

fn_exists() { declare -F "$1" >/dev/null; }

test_retry_until_extracted() {
  assert_ok "retry_until extracted (function-keyword-agnostic)" fn_exists retry_until
}

test_retry_until_success_first_try_no_sleep() {
  SLEEP_CALLS=0
  assert_ok "immediate success returns 0" retry_until 3 9 true
  assert_eq "${SLEEP_CALLS}" "0" "no sleep when the first attempt succeeds"
}

test_retry_until_no_trailing_sleep_on_exhaustion() {
  SLEEP_CALLS=0
  retry_until 3 9 false || true
  assert_eq "${SLEEP_CALLS}" "2" "3 failing attempts sleep only twice (no trailing sleep)"
}

test_retry_until_single_attempt_never_sleeps() {
  SLEEP_CALLS=0
  retry_until 1 9 false || true
  assert_eq "${SLEEP_CALLS}" "0" "a single attempt never sleeps"
}

test_retry_until_returns_failure_when_exhausted() {
  assert_fail "exhausted attempts return non-zero" retry_until 2 9 false
}

run_tests
