#!/usr/bin/env bash
# D5: set_env_kv / remove_env_kv (extracted from the installer). Covers the
# append-vs-update paths and value round-tripping through the sed-escape on update
# (backslash / ampersand / '|' delimiter), plus multi-line removal.
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091 # test-local helper, resolved at runtime
source ./lib.sh

INSTALL_SH="../../install/happier-install.sh"

eval "$(extract_function "${INSTALL_SH}" set_env_kv)"
eval "$(extract_function "${INSTALL_SH}" remove_env_kv)"

SB="$(mktemp -d)"
trap 'rm -rf "${SB}"' EXIT

val_of() { grep "^$2=" "$1" | tail -n1 | cut -d= -f2-; }
fn_exists() { declare -F "$1" >/dev/null; }

test_extracted() {
  assert_ok "set_env_kv extracted" fn_exists set_env_kv
  assert_ok "remove_env_kv extracted" fn_exists remove_env_kv
}

test_append_then_update_in_place() {
  local f="${SB}/a.env"
  : >"${f}"
  set_env_kv "${f}" "K1" "v1"
  assert_eq "$(grep -c '^K1=' "${f}")" "1" "K1 appended once"
  assert_eq "$(val_of "${f}" K1)" "v1" "K1=v1 after append"
  set_env_kv "${f}" "K1" "v2"
  assert_eq "$(grep -c '^K1=' "${f}")" "1" "K1 updated in place, still one line"
  assert_eq "$(val_of "${f}" K1)" "v2" "K1=v2 after update"
}

test_value_metachars_roundtrip() {
  local f="${SB}/m.env"
  : >"${f}"
  # append path writes the raw value
  set_env_kv "${f}" "URL" "https://a.example/x?y=1&z=2"
  assert_eq "$(val_of "${f}" URL)" "https://a.example/x?y=1&z=2" "append preserves & / and ?"
  # update path escapes sed metacharacters, then sed unescapes them back
  set_env_kv "${f}" "URL" 'a|b\c&d/e'
  assert_eq "$(val_of "${f}" URL)" 'a|b\c&d/e' "update preserves | \\ & /"
}

test_remove_all_matching_lines() {
  local f="${SB}/r.env"
  printf 'A=1\nB=2\nA=3\n' >"${f}"
  remove_env_kv "${f}" "A"
  assert_eq "$(grep -c '^A=' "${f}")" "0" "every A= line removed"
  assert_eq "$(grep -c '^B=' "${f}")" "1" "B= untouched"
}

test_remove_missing_file_is_noop() {
  assert_ok "remove on a missing file returns 0" remove_env_kv "${SB}/does-not-exist.env" "X"
}

run_tests
