#!/usr/bin/env bash
# Runner for the fork-owned happier test suite. Usage: bash tests/happier/run.sh
# Runs every test_*.sh in this directory in a fresh bash process; fails if any fail.
set -u
cd "$(dirname "$0")" || exit 1

overall=0
for f in test_*.sh; do
  echo "== ${f}"
  if ! bash "${f}"; then
    overall=1
  fi
done
if [[ "${overall}" -eq 0 ]]; then
  echo "ALL TEST FILES PASSED"
else
  echo "TEST FAILURES PRESENT" >&2
fi
exit "${overall}"
