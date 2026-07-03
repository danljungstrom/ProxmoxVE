#!/usr/bin/env bash
# D1: fixture tests for install_managed_ui_bundle's verify + swap flow
# (misc/happier-common.func). Network and filesystem are fully sandboxed:
# release resolution and downloads are stubbed to a fixture dir, and the
# channel data dirs point at a temp sandbox.
#
# Two tiers:
#   - stub-minisign tier (always runs): a fake `minisign` on PATH exercises the
#     sha256 check, extraction, atomic swap, refresh-degrade and install-abort paths.
#   - real-crypto tier (runs when minisign is installed, e.g. in CI): generates a
#     throwaway keypair via HAPPIER_MINISIGN_PUBKEY override and asserts good/bad
#     signature behavior end to end.
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091 # test-local helper, resolved at runtime
source ./lib.sh

SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
FIXTURE_DIR="${SANDBOX}/fixtures"
DATA_DIR="${SANDBOX}/data"
mkdir -p "${FIXTURE_DIR}" "${DATA_DIR}"

VERSION="9.9.9"
ARCHIVE_NAME="happier-ui-web-v${VERSION}-web-any.tar.gz"
CHECKSUMS_NAME="checksums-happier-ui-web-v${VERSION}.txt"

msg_warn() { :; }
msg_error() { echo "ERR: $*" >&2; }
msg_info() { :; }
msg_ok() { :; }

# Any non-default value; the stub tier never verifies it, the real tier replaces it.
export HAPPIER_MINISIGN_PUBKEY="test-key-placeholder"
# shellcheck disable=SC1091 # unit under test, resolved at runtime
source ../../misc/happier-common.func

# --- sandbox the paths + network ---------------------------------------------
channel_data_dir() { printf '%s' "${DATA_DIR}/happier-$1"; }
channel_ui_current_dir() { printf '%s' "$(channel_data_dir "$1")/ui-web/current"; }
resolve_happier_release_json_for_tags() {
  cat <<JSON
{"assets": [
  {"name": "${CHECKSUMS_NAME}", "browser_download_url": "stub://${CHECKSUMS_NAME}"},
  {"name": "${CHECKSUMS_NAME}.minisig", "browser_download_url": "stub://${CHECKSUMS_NAME}.minisig"},
  {"name": "${ARCHIVE_NAME}", "browser_download_url": "stub://${ARCHIVE_NAME}"}
]}
JSON
}
download_file() { # url dest retries verbose — copy from the fixture dir by basename
  cp "${FIXTURE_DIR}/$(basename "$1")" "$2" 2>/dev/null
}

make_fixtures() { # rebuilds a pristine fixture set
  rm -rf "${FIXTURE_DIR}" "${DATA_DIR}"
  mkdir -p "${FIXTURE_DIR}" "${DATA_DIR}"
  local staging="${SANDBOX}/bundle"
  rm -rf "${staging}"
  mkdir -p "${staging}"
  echo "<html>ui v${VERSION}</html>" >"${staging}/index.html"
  tar -czf "${FIXTURE_DIR}/${ARCHIVE_NAME}" -C "${staging}" index.html
  (cd "${FIXTURE_DIR}" && sha256sum "${ARCHIVE_NAME}" >"${CHECKSUMS_NAME}")
  echo "placeholder-signature" >"${FIXTURE_DIR}/${CHECKSUMS_NAME}.minisig"
}

use_fake_minisign() { # $1 = exit code the fake should return
  mkdir -p "${SANDBOX}/bin"
  printf '#!/usr/bin/env bash\nexit %s\n' "$1" >"${SANDBOX}/bin/minisign"
  chmod +x "${SANDBOX}/bin/minisign"
  export PATH="${SANDBOX}/bin:${PATH}"
}

drop_fake_minisign() {
  rm -f "${SANDBOX}/bin/minisign"
  hash -r
}

# --- stub-minisign tier --------------------------------------------------------

test_install_happy_path_and_same_version_refresh() {
  make_fixtures
  use_fake_minisign 0
  local out=""
  out="$(install_managed_ui_bundle stable install)" || {
    fail "install verb failed on valid fixtures"
    return
  }
  assert_eq "${out}" "$(channel_ui_current_dir stable)" "prints ui current dir"
  assert_ok "current symlink resolves" test -f "$(channel_ui_current_dir stable)/index.html"
  # Same-version refresh: the A6 regression case — the live version dir is replaced,
  # the symlink must still resolve afterwards and no .old.* debris may remain.
  out="$(install_managed_ui_bundle stable refresh)" || {
    fail "same-version refresh failed"
    return
  }
  assert_ok "symlink still resolves after refresh" test -f "$(channel_ui_current_dir stable)/index.html"
  local debris=""
  debris="$(find "$(channel_data_dir stable)/ui-web/versions" -maxdepth 1 -name '*.old.*' 2>/dev/null)"
  assert_eq "${debris}" "" "no .old.* debris left behind"
}

test_tampered_archive_fails_sha256_refresh_degrades() {
  make_fixtures
  use_fake_minisign 0
  echo "tampered" >>"${FIXTURE_DIR}/${ARCHIVE_NAME}"
  if install_managed_ui_bundle stable refresh >/dev/null 2>&1; then
    fail "tampered archive passed the sha256 check"
  fi
}

test_tampered_archive_install_verb_exits() {
  make_fixtures
  use_fake_minisign 0
  echo "tampered" >>"${FIXTURE_DIR}/${ARCHIVE_NAME}"
  local rc=0
  (install_managed_ui_bundle stable install >/dev/null 2>&1) || rc=$?
  assert_eq "${rc}" "1" "install verb exits 1 on tampered archive"
}

test_bad_signature_fails_via_minisign_rc() {
  make_fixtures
  use_fake_minisign 1 # minisign says NO
  if install_managed_ui_bundle stable refresh >/dev/null 2>&1; then
    fail "refresh succeeded although minisign rejected the signature"
  fi
}

test_missing_archive_asset_fails() {
  make_fixtures
  use_fake_minisign 0
  rm -f "${FIXTURE_DIR}/${ARCHIVE_NAME}"
  if install_managed_ui_bundle stable refresh >/dev/null 2>&1; then
    fail "refresh succeeded with the archive asset missing"
  fi
}

test_missing_minisign_binary_fails() {
  make_fixtures
  drop_fake_minisign
  if command -v minisign >/dev/null 2>&1; then
    skip "real minisign installed; the missing-binary branch is untestable here"
    return
  fi
  if install_managed_ui_bundle stable refresh >/dev/null 2>&1; then
    fail "refresh succeeded without any minisign binary"
  fi
}

# --- real-crypto tier -----------------------------------------------------------

test_real_minisign_good_and_bad_signature() {
  drop_fake_minisign
  if ! command -v minisign >/dev/null 2>&1; then
    skip "minisign not installed (CI installs it)"
    return
  fi
  make_fixtures
  local keydir="${SANDBOX}/keys"
  mkdir -p "${keydir}"
  minisign -f -G -W -p "${keydir}/test.pub" -s "${keydir}/test.key" >/dev/null 2>&1 || {
    fail "could not generate a test minisign keypair"
    return
  }
  minisign -S -W -s "${keydir}/test.key" -m "${FIXTURE_DIR}/${CHECKSUMS_NAME}" \
    -x "${FIXTURE_DIR}/${CHECKSUMS_NAME}.minisig" >/dev/null 2>&1 || {
    fail "could not sign the fixture checksums"
    return
  }
  # shellcheck disable=SC2034 # consumed by the sourced install_managed_ui_bundle
  MINISIGN_PUBKEY="$(cat "${keydir}/test.pub")"
  local out=""
  out="$(install_managed_ui_bundle stable install)" || {
    fail "install failed with a genuine valid signature"
    return
  }
  assert_ok "current symlink resolves (real sig)" test -f "$(channel_ui_current_dir stable)/index.html"
  # Now corrupt the signed file: signature must no longer verify.
  echo "# drift" >>"${FIXTURE_DIR}/${CHECKSUMS_NAME}"
  if install_managed_ui_bundle stable refresh >/dev/null 2>&1; then
    fail "refresh succeeded although the checksums file no longer matches its signature"
  fi
}

run_tests
