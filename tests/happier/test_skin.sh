#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016 # stub engine globals; snippets expand in the child shell
# happier_apply_skin (misc/happier-common.func) over a stub engine, plus an
# engine-contract test against the pinned community-scripts/core ref: the skin
# overrides engine internals, so a core bump that renames them must fail here.
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091 # test-local helper, resolved at runtime
source ./lib.sh

msg_warn() { :; }
msg_error() { echo "ERR: $*" >&2; }
msg_info() { :; }
msg_ok() { :; }
# shellcheck disable=SC1091 # unit under test, resolved at runtime
source ../../misc/happier-common.func

SB="$(mktemp -d)"
trap 'rm -rf "${SB}"' EXIT
# A fake whiptail on PATH: records its args, exits with FAKE_WT_RC.
cat >"${SB}/whiptail" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${WT_LOG}"
exit "${FAKE_WT_RC:-0}"
EOF
chmod +x "${SB}/whiptail"
export PATH="${SB}:${PATH}" WT_LOG="${SB}/wt.log"

# Run a snippet in a fresh shell holding a stub engine and the unit under test.
in_engine() {
  bash -c '
    set -Eeuo pipefail
    msg_warn() { :; }; msg_error() { :; }; msg_info() { :; }; msg_ok() { :; }
    color() { YW="engine-yw"; GN="engine-gn"; CL="engine-cl"; [[ -n "${dev_mode:-}" ]] && GN="engine-red" || true; }
    color_spinner() { CS_YWB="engine-spin"; }
    get_header() { echo "engine-header"; }
    TAB="  "
    source ../../misc/happier-common.func
    '"$1"
}

test_palette_applied_and_survives_color_reruns() {
  local out
  out="$(in_engine 'happier_apply_skin; YW=reset; color; printf "%q|%q|%s" "$YW" "$GN" "$CL"')"
  assert_eq "${out}" "$'\\E[38;5;255m'|$'\\E[1;38;5;41m'|engine-cl" "palette re-applied on top of the engine color()"
}

test_dev_mode_keeps_engine_greens() {
  local out
  out="$(in_engine 'dev_mode=1; happier_apply_skin; printf "%s" "$GN"')"
  assert_eq "${out}" "engine-red" "dev-mode red untouched"
}

test_apply_twice_does_not_recurse() {
  local out
  out="$(in_engine 'happier_apply_skin; happier_apply_skin; color; echo ok')"
  assert_eq "${out}" "ok" "idempotent"
}

test_opt_out_and_no_engine_are_noops() {
  local out
  out="$(in_engine 'HAPPIER_PVE_SKIN=0; happier_apply_skin; color; printf "%s|%s" "$YW" "$(get_header)"')"
  assert_eq "${out}" "engine-yw|engine-header" "HAPPIER_PVE_SKIN=0 keeps the stock look"
  out="$(bash -c 'source ../../misc/happier-common.func; happier_apply_skin; declare -F whiptail || echo none')"
  assert_eq "${out}" "none" "no engine loaded -> nothing overridden"
}

test_icons_are_skinned() {
  local out
  out="$(in_engine 'happier_apply_skin; printf "%s\n" "$CM" "$INFO" "$DISKSIZE"' | sed 's/\x1b\[[0-9;]*m//g')"
  assert_eq "${out}" $'  ✔  \n  ◆  \n  ▸  ' "glyph icons replace the emoji"
}

test_spinner_and_banner() {
  local out
  out="$(in_engine 'happier_apply_skin; color_spinner; printf "%q" "$CS_YWB"')"
  assert_eq "${out}" "$'\\E[1;38;5;179m'" "amber spinner"
  out="$(in_engine 'happier_apply_skin; get_header' | sed 's/\x1b\[[0-9;]*m//g')"
  assert_ok "banner art" grep -qF '/_/ /_/\__,_/ .___/ .___/_/\___/_/' <<<"${out}"
  assert_ok "tagline" grep -q 'Happier for Proxmox VE · https://happier.dev' <<<"${out}"
  assert_eq "$(wc -l <<<"${out}")" "8" "top padding + 6 art lines + tagline"
}

test_truecolor_when_advertised() {
  assert_eq "$(COLORTERM=truecolor _happier_sgr e0b65a 179 1 | od -An -c | tr -d ' \n')" \
    '033[1;38;2;224;182;90m' "24-bit SGR"
}

test_whiptail_backtitle_rewritten_and_rc_kept() {
  local rc=0
  in_engine 'happier_apply_skin; whiptail --backtitle "Proxmox VE Helper Scripts [Step 2/9]" --msgbox "hi" 8 40' || rc=$?
  assert_ok "backtitle rewritten" grep -qxF 'Happier for Proxmox VE [Step 2/9]' "${WT_LOG}"
  assert_eq "${rc}" "0" "rc 0"
  rc=0
  FAKE_WT_RC=1 in_engine 'happier_apply_skin; whiptail --yesno "q" 8 40' || rc=$?
  assert_eq "${rc}" "1" "Cancel status passes through"
}

test_whiptail_update_menu_reworded() {
  in_engine 'APP=Happier; happier_apply_skin; whiptail --backtitle "Proxmox VE Helper Scripts" --title "Happier LXC Update/Setting" --menu "Support/Update functions for Happier LXC. Choose an option:" 12 60 3 "1" "YES (Silent Mode)" "2" "YES (Verbose Mode)" "3" "NO (Cancel Update)" --nocancel --default-item "1"'
  assert_eq "$(tr '\n' '|' <"${WT_LOG}")" \
    "--backtitle|Happier for Proxmox VE|--title|Update Happier|--menu|Updates the Happier CLI and relay in this container. Your settings and data are kept.|12|66|3|1|Update now|2|Update and show full command output|3|Cancel|--nocancel|--default-item|1|" \
    "wording, size; tags 1/2/3 untouched"
  in_engine 'happier_apply_skin; whiptail --title "Settings" --menu "pick" 12 60 3 "1" "YES (Silent Mode)"'
  assert_eq "$(tr '\n' '|' <"${WT_LOG}")" "--title|Settings|--menu|pick|12|60|3|1|YES (Silent Mode)|" "other dialogs untouched"
}

test_newt_colors_preset_wins() {
  assert_eq "$(TERM=xterm-256color in_engine 'happier_apply_skin; printf "%s" "$NEWT_COLORS"' | cut -c1-25)" "root=color255,color233;ro" "256-color palette"
  assert_eq "$(TERM=linux COLORTERM='' in_engine 'tput() { echo 8; }; happier_apply_skin; printf "%s" "$NEWT_COLORS"' | cut -c1-16)" "root=white,black" "16-color fallback"
  assert_eq "$(NEWT_COLORS="root=red,red" in_engine 'happier_apply_skin; printf "%s" "$NEWT_COLORS"')" "root=red,red" "user palette kept"
}

# The overridden names must still exist at the pinned engine ref. Network test:
# skipped offline, always runs in CI.
test_engine_contract_at_pinned_ref() {
  local ref base dir="${SB}/core"
  ref="$(sed -n 's/^HAPPIER_CORE_REF="\([0-9a-f]*\)"$/\1/p' ../../ct/happier.sh)"
  base="https://raw.githubusercontent.com/community-scripts/core/${ref}"
  mkdir -p "${dir}"
  if ! curl -fsSL --max-time 30 "${base}/core/core.func" -o "${dir}/core.func" ||
    ! curl -fsSL --max-time 30 "${base}/ui/menu.func" -o "${dir}/menu.func"; then
    skip "engine not reachable"
    return 0
  fi
  local fn
  for fn in color icons color_spinner get_header header_info load_functions; do
    assert_ok "core.func defines ${fn}()" grep -q "^${fn}() {" "${dir}/core.func"
  done
  assert_ok "header_info draws get_header" grep -q 'header_content=$(get_header' "${dir}/core.func"
  assert_ok "load_functions runs once (guard)" grep -q '__FUNCTIONS_LOADED' "${dir}/core.func"
  assert_ok "dialogs carry the backtitle string" grep -q 'backtitle "Proxmox VE Helper Scripts' "${dir}/menu.func"
  local s
  for s in '--title "${APP} LXC Update/Setting" --menu' '"Support/Update functions for ${APP} LXC. Choose an option:"' \
    '12 60 3' '"1" "YES (Silent Mode)"' '"2" "YES (Verbose Mode)"' '"3" "NO (Cancel Update)"'; do
    assert_ok "update menu still says: ${s}" grep -qF -- "${s}" "${dir}/menu.func"
  done
  assert_ok "spinner colors via CS_YWB" grep -q 'CS_YWB}${chars' "${dir}/core.func"
}

run_tests
