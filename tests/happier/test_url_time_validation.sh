#!/usr/bin/env bash
# D3: edge-case tests for the pure validators. The shared ones come from
# misc/happier-common.func; the installer-only ones are extracted from
# install/happier-install.sh by name (it runs a main flow, so it cannot be sourced).
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091 # test-local helper, resolved at runtime
source ./lib.sh

INSTALL_SH="../../install/happier-install.sh"
msg_warn() { :; }
msg_error() { echo "ERR: $*" >&2; }

# shellcheck disable=SC1091 # unit under test, resolved at runtime
source ../../misc/happier-common.func
# is_valid_github_pat is a one-liner, not extract_function-shaped — pull it verbatim.
eval "$(grep '^is_valid_github_pat()' "${INSTALL_SH}")"
eval "$(extract_function "${INSTALL_SH}" normalize_url_no_trailing_slash)"
eval "$(extract_function "${INSTALL_SH}" extract_https_url_from_text)"

fn_exists() { declare -F "$1" >/dev/null; }

test_extraction_worked() {
  assert_ok "is_valid_hhmm extracted" fn_exists is_valid_hhmm
  assert_ok "is_valid_github_pat extracted" fn_exists is_valid_github_pat
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

test_is_valid_github_pat() {
  assert_ok "classic hex token" is_valid_github_pat "ghp_ABCdef0123456789"
  assert_ok "fine-grained token (underscores)" is_valid_github_pat "github_pat_11ABC_def456"
  assert_ok "plain alnum" is_valid_github_pat "abc123XYZ"
  assert_fail "empty rejected" is_valid_github_pat ""
  assert_fail "dash rejected" is_valid_github_pat "ghp-with-dash"
  assert_fail "space rejected" is_valid_github_pat "has space"
  assert_fail "shell metachar rejected" is_valid_github_pat 'tok;rm -rf'
  assert_fail "quote rejected" is_valid_github_pat 'tok"quote'
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
  assert_eq "$(normalize_https_public_url_or_empty "https://[2001:db8::1]:8443/app/")" "https://[2001:db8::1]:8443/app" "IPv6 authority brackets preserved"
  assert_eq "$(normalize_https_public_url_or_empty "https://[::1]/")" "https://[::1]" "IPv6 without explicit port"
  # D12: documented port-preserve + query/hash-drop behavior.
  assert_eq "$(normalize_https_public_url_or_empty "https://happier.example.com:8443")" "https://happier.example.com:8443" "explicit port preserved"
  assert_eq "$(normalize_https_public_url_or_empty "https://happier.example.com:8443/")" "https://happier.example.com:8443" "port preserved with trailing slash stripped"
  assert_eq "$(normalize_https_public_url_or_empty "https://happier.example.com/app?token=abc")" "https://happier.example.com/app" "query string dropped"
  assert_eq "$(normalize_https_public_url_or_empty "https://happier.example.com/app#frag")" "https://happier.example.com/app" "fragment dropped"
  assert_eq "$(normalize_https_public_url_or_empty "https://happier.example.com:8443/app/?x=1#y")" "https://happier.example.com:8443/app" "port kept, path kept, query+hash+slash dropped"
}

# shellcheck disable=SC2016 # variables and substitutions belong to the child shell
test_app_questions_rejects_invalid_presets() {
  local rc=0
  env PHS_SILENT=1 HAPPIER_PVE_AUTOSTART=false bash -c '
    source ./lib.sh
    source ../../misc/happier-common.func
    msg_error() { :; }
    eval "$(extract_function ../../ct/happier.sh app_questions)"
    app_questions
  ' || rc=$?
  assert_eq "${rc}" 1 "invalid boolean preset rejected before prompting"
}

# shellcheck disable=SC2016 # literal attack input and child-shell expansion are intentional
test_installer_rejects_invalid_port_before_setup() {
  local value rc dir attack
  dir="$(mktemp -d)"
  printf -v attack '$(: > "%s/port-evaluated")' "${dir}"
  for value in 0 65536 "${attack}"; do
    rc=0
    env HAPPIER_PVE_SERVER_PORT="${value}" bash -c '
      source ../../misc/happier-common.func
      msg_error() { :; }
      eval "$(sed -n "/^validate_happier_presets || exit 1$/,/^HAPPIER_SERVER_PORT=/p" ../../install/happier-install.sh)"
    ' || rc=$?
    assert_eq "${rc}" 1 "invalid TCP port rejected before setup"
    assert_fail "rejected port text is never evaluated" test -e "${dir}/port-evaluated"
  done
  rm -rf "${dir}"
}

test_valid_presets_preserve_defaults_and_tcp_boundary() {
  assert_ok "absent presets retain defaults" validate_happier_presets
  assert_ok "disabled preset remains valid" env HAPPIER_PVE_AUTOSTART=0 bash -c 'source ../../misc/happier-common.func; validate_happier_presets'
  assert_ok "maximum valid port accepted" env HAPPIER_PVE_SERVER_PORT=65535 bash -c 'source ../../misc/happier-common.func; validate_happier_presets'
  assert_ok "decimal port with leading zeros accepted" env HAPPIER_PVE_SERVER_PORT=0003005 bash -c 'source ../../misc/happier-common.func; validate_happier_presets'
}

test_extract_https_url_from_text() {
  assert_eq "$(printf 'foo https://a.example/x bar\n' | extract_https_url_from_text)" "https://a.example/x" "url extracted from text"
  assert_eq "$(printf 'no urls here\n' | extract_https_url_from_text)" "" "no url -> empty"
}

run_tests
