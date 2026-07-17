#!/usr/bin/env bash
# Runner for the fork-owned happier test suite. Usage: bash tests/happier/run.sh
# Runs every test_*.sh in this directory in a fresh bash process; fails if any fail.
set -u
cd "$(dirname "$0")" || exit 1

overall=0
for f in test_*.sh; do
  echo "== ${f}"
  # Capture so we can both show the output and assert the file actually ran tests:
  # a file that never calls run_tests (or runs zero) would otherwise pass silently.
  out="$(bash "${f}")"
  rc=$?
  printf '%s\n' "${out}"
  if [[ ${rc} -ne 0 ]]; then
    overall=1
  fi
  if ! printf '%s\n' "${out}" | grep -Eq '^# [1-9][0-9]* tests,'; then
    echo "PLAN FAIL: ${f} reported no run tests (missing run_tests?)" >&2
    overall=1
  fi
done
if [[ "${overall}" -eq 0 ]]; then
  echo "ALL TEST FILES PASSED"
else
  echo "TEST FAILURES PRESENT" >&2
fi
exit "${overall}"
