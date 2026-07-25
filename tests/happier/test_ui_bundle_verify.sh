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

# (Re)build the remote release fixture for one version, leaving any already-
# installed bundle under DATA_DIR intact (so a test can install one version then
# serve a different one for a refresh). Retargets the ARCHIVE_NAME/CHECKSUMS_NAME
# globals the release-JSON stub advertises.
build_release_fixture() { # version
  VERSION="$1"
  ARCHIVE_NAME="happier-ui-web-v${VERSION}-web-any.tar.gz"
  CHECKSUMS_NAME="checksums-happier-ui-web-v${VERSION}.txt"
  rm -rf "${FIXTURE_DIR}"
  mkdir -p "${FIXTURE_DIR}"
  local staging="${SANDBOX}/bundle-${VERSION}"
  rm -rf "${staging}"
  mkdir -p "${staging}"
  echo "<html>ui v${VERSION}</html>" >"${staging}/index.html"
  tar -czf "${FIXTURE_DIR}/${ARCHIVE_NAME}" -C "${staging}" index.html
  (cd "${FIXTURE_DIR}" && sha256sum "${ARCHIVE_NAME}" >"${CHECKSUMS_NAME}")
  echo "placeholder-signature" >"${FIXTURE_DIR}/${CHECKSUMS_NAME}.minisig"
}

make_fixtures() { # rebuilds a pristine fixture set + empty install dir (version 9.9.9)
  rm -rf "${FIXTURE_DIR}" "${DATA_DIR}"
  mkdir -p "${FIXTURE_DIR}" "${DATA_DIR}"
  build_release_fixture "9.9.9"
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

# D11: hermetic minisign-hiding. With _hide_minisign=1 the command override reports
# minisign as absent, so the missing-binary branch runs even in CI where real
# minisign is installed. Top-level def (invoked indirectly), so not flagged SC2329.
_hide_minisign=0
command() {
  if [[ "${_hide_minisign}" -eq 1 && "${1:-}" == "-v" && "${2:-}" == "minisign" ]]; then
    return 1
  fi
  builtin command "$@"
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
  # Same-version refresh now short-circuits (P1): no re-download, the symlink must
  # still resolve and no .old.*/.tmp.* debris may be left behind.
  out="$(install_managed_ui_bundle stable refresh)" || {
    fail "same-version refresh failed"
    return
  }
  assert_ok "symlink still resolves after refresh" test -f "$(channel_ui_current_dir stable)/index.html"
  local debris=""
  debris="$(find "$(channel_data_dir stable)/ui-web/versions" -maxdepth 1 \( -name '*.old.*' -o -name '*.tmp.*' \) 2>/dev/null)"
  assert_eq "${debris}" "" "no .old.*/.tmp.* debris left behind"
}

test_refresh_newer_version_swaps() { # A6/A7: swap the live bundle to a newer version
  # NB: this asserts the swap RESULT (current -> new version, no debris), not the
  # atomicity of the symlink swap itself. A6's no-observable-gap property comes from
  # `mv -T` (a single rename(2)) and can't be proven without a concurrent reader.
  make_fixtures
  use_fake_minisign 0
  install_managed_ui_bundle stable install >/dev/null || {
    fail "install 9.9.9 failed"
    return
  }
  build_release_fixture "9.9.10" # remote now serves a newer bundle
  install_managed_ui_bundle stable refresh >/dev/null || {
    fail "refresh to 9.9.10 failed"
    return
  }
  assert_ok "current resolves after upgrade" test -f "$(channel_ui_current_dir stable)/index.html"
  assert_eq "$(cat "$(channel_ui_current_dir stable)/index.html")" "<html>ui v9.9.10</html>" "current serves the upgraded version"
  local debris=""
  debris="$(find "$(channel_data_dir stable)/ui-web/versions" -maxdepth 1 \( -name '*.old.*' -o -name '*.tmp.*' \) 2>/dev/null)"
  assert_eq "${debris}" "" "no staging/backup debris after upgrade"
}

test_refresh_same_version_skips_download() { # P1: current already installed -> no fetch
  make_fixtures
  use_fake_minisign 0
  install_managed_ui_bundle stable install >/dev/null || {
    fail "install 9.9.9 failed"
    return
  }
  # Remove the archive so any download attempt fails; a same-version refresh must
  # still succeed because P1 short-circuits before downloading/verifying.
  rm -f "${FIXTURE_DIR}/${ARCHIVE_NAME}"
  install_managed_ui_bundle stable refresh >/dev/null || {
    fail "same-version refresh re-fetched instead of short-circuiting (P1)"
    return
  }
  assert_ok "current still resolves after skipped refresh" test -f "$(channel_ui_current_dir stable)/index.html"
}

test_refresh_older_version_refused() { # B3: reject a downgrade to an older signed bundle
  make_fixtures
  use_fake_minisign 0
  install_managed_ui_bundle stable install >/dev/null || {
    fail "install 9.9.9 failed"
    return
  }
  build_release_fixture "9.9.8" # remote serves an OLDER bundle
  if install_managed_ui_bundle stable refresh >/dev/null 2>&1; then
    fail "refresh accepted a downgrade to 9.9.8"
  fi
  assert_eq "$(cat "$(channel_ui_current_dir stable)/index.html")" "<html>ui v9.9.9</html>" "downgrade left the installed version intact"
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
  # D11: hide minisign hermetically so this runs everywhere (was skipped when a
  # real minisign was on PATH).
  _hide_minisign=1
  local rc=0
  install_managed_ui_bundle stable refresh >/dev/null 2>&1 || rc=$?
  _hide_minisign=0
  assert_eq "${rc}" "1" "refresh degrades (rc 1) when no minisign binary is present"
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
  # Corrupting the *same* version can't be observed through refresh: P1 short-
  # circuits an already-installed version before re-downloading/verifying (see
  # test_refresh_same_version_skips_download). Serve a NEWER version, sign it,
  # then corrupt it so the download+verify path runs and minisign must reject the
  # broken signature.
  build_release_fixture "9.9.10"
  minisign -S -W -s "${keydir}/test.key" -m "${FIXTURE_DIR}/${CHECKSUMS_NAME}" \
    -x "${FIXTURE_DIR}/${CHECKSUMS_NAME}.minisig" >/dev/null 2>&1 || {
    fail "could not sign the 9.9.10 fixture checksums"
    return
  }
  echo "# drift" >>"${FIXTURE_DIR}/${CHECKSUMS_NAME}"
  if install_managed_ui_bundle stable refresh >/dev/null 2>&1; then
    fail "refresh succeeded although the checksums file no longer matches its signature"
  fi
}

run_tests
