#!/usr/bin/env bash
# D3: edge-case tests for the installer's pure validators. The functions are
# extracted from install/happier-install.sh by name (the script itself runs a
# main flow, so it cannot be sourced whole).
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091 # test-local helper, resolved at runtime
source ./lib.sh

INSTALL_SH="../../install/happier-install.sh"
msg_warn() { :; }
msg_error() { echo "ERR: $*" >&2; }

# is_valid_hhmm is a one-liner, not extract_function-shaped — pull it verbatim.
eval "$(grep '^is_valid_hhmm()' "${INSTALL_SH}")"
eval "$(extract_function "${INSTALL_SH}" normalize_url_no_trailing_slash)"
eval "$(extract_function "${INSTALL_SH}" normalize_https_public_url_or_empty)"
eval "$(extract_function "${INSTALL_SH}" extract_https_url_from_text)"

fn_exists() { declare -F "$1" >/dev/null; }

test_extraction_worked() {
  assert_ok "is_valid_hhmm extracted" fn_exists is_valid_hhmm
  assert_ok "normalize_url_no_trailing_slash extracted" fn_exists normalize_url_no_trailing_slash
  assert_ok "normalize_https_public_url_or_empty extracted" fn_exists normalize_https_public_url_or_empty
  assert_ok "extract_https_url_from_text extracted" fn_exists extract_https_url_from_text
}

test_is_valid_hhmm() {
  assert_ok "00:00" is_valid_hhmm "00:00"
  assert_ok "23:59" is_valid_hhmm "23:59"
  assert_ok "04:00" is_valid_hhmm "04:00"
  assert_fail "24:00 rejected" is_valid_hhmm "24:00"
  assert_fail "4:00 rejected (needs leading zero)" is_valid_hhmm "4:00"
  assert_fail "12:60 rejected" is_valid_hhmm "12:60"
  assert_fail "empty rejected" is_valid_hhmm ""
  assert_fail "garbage rejected" is_valid_hhmm "noon"
}

test_normalize_url_no_trailing_slash() {
  assert_eq "$(normalize_url_no_trailing_slash "https://x.example/")" "https://x.example" "single slash"
  assert_eq "$(normalize_url_no_trailing_slash "https://x.example///")" "https://x.example" "multi slash"
  assert_eq "$(normalize_url_no_trailing_slash $'https://x.example\r')" "https://x.example" "CR stripped"
  assert_eq "$(normalize_url_no_trailing_slash "  https://x.example  ")" "https://x.example" "whitespace trimmed"
}

test_normalize_https_public_url_or_empty() {
  # The embedded python3 program is the regression target: a syntax error in it
  # degrades to "" for VALID input, which is exactly what the happy-path assert catches.
  assert_eq "$(normalize_https_public_url_or_empty "https://happier.example.com")" "https://happier.example.com" "valid https passes through"
  assert_eq "$(normalize_https_public_url_or_empty "https://happier.example.com/")" "https://happier.example.com" "trailing slash normalized"
  assert_eq "$(normalize_https_public_url_or_empty "http://happier.example.com")" "" "http rejected"
  assert_eq "$(normalize_https_public_url_or_empty "https://user:pw@happier.example.com")" "" "credentials rejected"
  assert_eq "$(normalize_https_public_url_or_empty "https://")" "" "empty host rejected"
  assert_eq "$(normalize_https_public_url_or_empty "not a url")" "" "garbage rejected"
  assert_eq "$(normalize_https_public_url_or_empty "")" "" "empty rejected"
}

test_extract_https_url_from_text() {
  assert_eq "$(printf 'foo https://a.example/x bar\n' | extract_https_url_from_text)" "https://a.example/x" "url extracted from text"
  assert_eq "$(printf 'no urls here\n' | extract_https_url_from_text)" "" "no url -> empty"
}

run_tests
