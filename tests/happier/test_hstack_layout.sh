#!/usr/bin/env bash
# D8: resolve_hstack_layout jq parsing + workspace 3-way fallback.
# D9: resolve_ui_extract_root flat / nested / missing index.html.
# Both live in misc/happier-common.func and are sourced directly.
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091 # test-local helper, resolved at runtime
source ./lib.sh

msg_warn() { :; }
msg_error() { echo "ERR: $*" >&2; }
msg_info() { :; }
msg_ok() { :; }
# Any non-default value; keeps the source-time key-override warning quiet.
export HAPPIER_MINISIGN_PUBKEY="test-key-placeholder"
# shellcheck disable=SC1091 # unit under test, resolved at runtime
source ../../misc/happier-common.func

SB="$(mktemp -d)"
trap 'rm -rf "${SB}"' EXIT

# resolve_hstack_layout runs `sudo -u happier -H <bin> where --json`. Strip the
# `-u happier -H` prefix so the fake hstack runs directly (top-level def, so it is
# not flagged SC2329 for being called only indirectly).
sudo() {
  shift 3
  "$@"
}

make_hstack() { # $1 = JSON body the fake `hstack where --json` should print
  local b="${SB}/hstack"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'cat <<'\''JSON'\''\n'
    printf '%s\n' "$1"
    printf 'JSON\n'
  } >"${b}"
  chmod +x "${b}"
  printf '%s' "${b}"
}

# --- D8 ---------------------------------------------------------------------

test_resolve_hstack_layout_full() {
  command -v jq >/dev/null 2>&1 || {
    skip "jq not installed"
    return
  }
  local hb
  hb="$(make_hstack '{"homeDir":"/home/h/.stack","stack":{"name":"main","label":"dev.h.stack"},"envFiles":{"main":{"path":"/home/h/.happier/stacks/main/env"}},"workspaceDir":"/home/h/.stack/workspace/main"}')"
  resolve_hstack_layout "${hb}"
  assert_eq "${HSTACK_WHERE_HOME}" "/home/h/.stack" "homeDir parsed"
  assert_eq "${HSTACK_WHERE_NAME}" "main" "stack.name parsed"
  assert_eq "${HSTACK_WHERE_LABEL}" "dev.h.stack" "stack.label parsed"
  assert_eq "${HSTACK_WHERE_ENV}" "/home/h/.happier/stacks/main/env" "envFiles.main.path parsed"
  assert_eq "${HSTACK_WHERE_WORKSPACE}" "/home/h/.stack/workspace/main" "workspaceDir parsed"
}

test_resolve_hstack_layout_workspace_fallback() {
  command -v jq >/dev/null 2>&1 || {
    skip "jq not installed"
    return
  }
  # workspaceDir absent -> falls back to .workspace.dir
  local hb
  hb="$(make_hstack '{"homeDir":"/h","workspace":{"dir":"/h/ws"}}')"
  resolve_hstack_layout "${hb}"
  assert_eq "${HSTACK_WHERE_WORKSPACE}" "/h/ws" "workspace.dir fallback used"
  assert_eq "${HSTACK_WHERE_NAME}" "" "absent stack.name -> empty"
}

test_resolve_hstack_layout_bad_json_all_empty() {
  local hb
  hb="$(make_hstack 'this is not json')"
  resolve_hstack_layout "${hb}"
  assert_eq "${HSTACK_WHERE_HOME}" "" "bad json -> empty home (callers apply defaults)"
  assert_eq "${HSTACK_WHERE_ENV}" "" "bad json -> empty env"
}

# --- D9 ---------------------------------------------------------------------

test_ui_extract_root_flat() {
  local d="${SB}/flat"
  mkdir -p "${d}"
  : >"${d}/index.html"
  assert_eq "$(resolve_ui_extract_root "${d}")" "${d}" "top-level index.html -> extract dir"
}

test_ui_extract_root_nested() {
  local d="${SB}/nested"
  mkdir -p "${d}/dist"
  : >"${d}/dist/index.html"
  assert_eq "$(resolve_ui_extract_root "${d}")" "${d}/dist" "nested index.html -> its dir"
}

test_ui_extract_root_missing() {
  local d="${SB}/empty"
  mkdir -p "${d}/sub"
  assert_fail "no index.html -> returns non-zero" resolve_ui_extract_root "${d}"
}

run_tests
