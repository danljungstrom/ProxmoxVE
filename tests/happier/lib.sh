#!/usr/bin/env bash
# Tiny assert library for the happier test suite (no external deps).
# Each test file sources this, defines test_* functions, and ends with run_tests.

TESTS_RUN=0
TESTS_FAILED=0
TESTS_SKIPPED=0
CURRENT_TEST=""

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "not ok - ${CURRENT_TEST}: $*"
}

skip() {
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
  echo "ok - ${CURRENT_TEST} # SKIP $*"
  return 0
}

assert_eq() { # actual expected label
  if [[ "$1" != "$2" ]]; then
    fail "${3:-assert_eq}: expected [$2], got [$1]"
    return 1
  fi
  return 0
}

assert_ok() { # label cmd...
  local label="$1"
  shift
  if ! "$@"; then
    fail "${label}: expected success, got rc=$?"
    return 1
  fi
  return 0
}

assert_fail() { # label cmd...
  local label="$1"
  shift
  if "$@"; then
    fail "${label}: expected failure, got rc=0"
    return 1
  fi
  return 0
}

# Extract one top-level function (`name() {` ... `}` at column 0) from a script
# without executing the script's main flow. Handles both the POSIX `name()` form
# and the `function name()` keyword form (the latter is what defeats a bare
# `/^name() {/` match — e.g. ct/happier.sh's update_script/app_questions).
extract_function() { # file funcname
  sed -n "/^\(function \)\?$2() {/,/^}/p" "$1"
}

run_tests() {
  local t rc=0
  for t in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
    CURRENT_TEST="${t}"
    TESTS_RUN=$((TESTS_RUN + 1))
    local before_failed="${TESTS_FAILED}" before_skipped="${TESTS_SKIPPED}"
    "${t}"
    # Print the pass line only if the test neither failed nor already reported a
    # skip line (skip() prints its own "ok - ... # SKIP", so an extra "ok" here
    # would double-report the same test).
    if [[ "${TESTS_FAILED}" == "${before_failed}" && "${TESTS_SKIPPED}" == "${before_skipped}" ]]; then
      echo "ok - ${t}"
    fi
  done
  echo "# ${TESTS_RUN} tests, ${TESTS_FAILED} failed, ${TESTS_SKIPPED} skipped"
  [[ "${TESTS_FAILED}" -eq 0 ]] || rc=1
  return "${rc}"
}
