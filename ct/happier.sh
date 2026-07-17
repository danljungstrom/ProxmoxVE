#!/usr/bin/env bash
INSTALLER_REPO="${INSTALLER_REPO:-happier-dev/ProxmoxVE}"
# Supply chain: build.func is sourced from this ref (community-scripts framework
# model). It defaults to the moving 'main' branch; for a reproducible/pinned
# install, export INSTALLER_REF=<tag-or-sha> (the `update` helper honors it too).
INSTALLER_REF="${INSTALLER_REF:-main}"
export INSTALLER_REPO INSTALLER_REF

# Download a remote script and print its payload, failing hard on download error
# or empty body. Reports via msg_error once the framework is sourced (2nd call
# onward), plain stderr before that. NOTE: callers must `|| exit 1` (the exit here
# only leaves the command-substitution subshell) and must source the payload at
# top level, NOT inside a function (sourcing frameworks in a function scope would
# make their `declare` statements function-local).
fetch_remote_script() {
  local url="$1" label="$2"
  local payload=""
  payload="$(curl -fsSL "${url}")" || {
    if command -v msg_error >/dev/null 2>&1; then
      msg_error "Failed to download ${label} from: ${url}"
    else
      echo "Failed to download ${label} from: ${url}" >&2
    fi
    exit 1
  }
  if [[ -z "${payload//[[:space:]]/}" ]]; then
    if command -v msg_error >/dev/null 2>&1; then
      msg_error "Downloaded ${label} is empty: ${url}"
    else
      echo "Downloaded ${label} is empty: ${url}" >&2
    fi
    exit 1
  fi
  printf '%s' "${payload}"
}

BUILD_FUNC_URL="https://raw.githubusercontent.com/${INSTALLER_REPO}/${INSTALLER_REF}/misc/build.func"
BUILD_FUNC="$(fetch_remote_script "${BUILD_FUNC_URL}" "build.func")" || exit 1
# shellcheck disable=SC1091 # sourced from a runtime-fetched string, not a file
source /dev/stdin <<<"${BUILD_FUNC}"

# Shared Happier helpers (channel/UI-bundle/CLI resolvers). Fetched and sourced
# AFTER build.func so the framework msg_* helpers are available.
HAPPIER_COMMON_FUNC_URL="https://raw.githubusercontent.com/${INSTALLER_REPO}/${INSTALLER_REF}/misc/happier-common.func"
HAPPIER_COMMON_FUNC="$(fetch_remote_script "${HAPPIER_COMMON_FUNC_URL}" "happier-common.func")" || exit 1
# shellcheck disable=SC1091 # sourced from a runtime-fetched string, not a file
source /dev/stdin <<<"${HAPPIER_COMMON_FUNC}"

# Copyright (c) 2021-2026 community-scripts ORG
# Author: happier-dev
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://happier.dev

APP="Happier"
var_tags="${var_tags:-ai;devtools}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-32}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "${APP}"
variables
color
catch_errors

# NB: the `function` keyword on update_script/app_questions is the upstream
# community-scripts ct-template convention (kept for template parity); the rest
# of the fork's functions use the plain POSIX name() form.
function update_script() {
  header_info
  check_container_storage
  check_container_resources

  local installer_channel=""
  local installer_state_path=""
  local candidate_channel=""
  for candidate_channel in stable preview dev; do
    installer_state_path="$(channel_state_path "${candidate_channel}")"
    if [[ -f "${installer_state_path}" ]]; then
      installer_channel="${candidate_channel}"
      break
    fi
  done

  if [[ -n "${installer_channel}" ]]; then
    local cli_bin=""
    local config_env_path=""
    config_env_path="$(channel_config_env_path "${installer_channel}")"
    cli_bin="$(resolve_installed_cli_for_channel "${installer_channel}" || true)"
    if [[ -z "${cli_bin}" ]]; then
      msg_error "No channel-matched Happier CLI was found. Try reinstalling the Proxmox container."
      exit 1
    fi

    local ui_managed=0
    if [[ -f "${config_env_path}" ]] && grep -q '^HAPPIER_SERVER_UI_DIR=' "${config_env_path}"; then
      ui_managed=1
      msg_info "Refreshing ${APP} web UI bundle (channel: ${installer_channel})"
      if install_managed_ui_bundle "${installer_channel}" refresh >/dev/null; then
        msg_ok "Refreshed ${APP} web UI bundle"
      else
        msg_warn "UI bundle refresh failed; keeping the existing bundle"
      fi
    fi

    msg_info "Updating ${APP} CLI (channel: ${installer_channel})"
    local self_update_rc=0
    "${cli_bin}" self update --channel="${installer_channel}" >/dev/null 2>&1 || self_update_rc=$?
    cli_bin="$(resolve_installed_cli_for_channel "${installer_channel}" || true)"
    if [[ -z "${cli_bin}" ]]; then
      msg_error "Happier CLI missing after self-update. Try reinstalling the Proxmox container."
      exit 1
    fi
    if [[ "${self_update_rc}" -eq 0 ]]; then
      msg_ok "Updated ${APP} CLI"
    else
      msg_warn "CLI self-update failed (rc=${self_update_rc}); continuing with the existing CLI"
    fi

    local relay_service=""
    relay_service="$(channel_relay_service_name "${installer_channel}")"
    # Preserve the user's autostart choice: an install with autostart disabled
    # leaves the relay unit present but disabled+inactive, and the reinstall below
    # can re-enable it. Capture the prior state and restore it afterward.
    local relay_was_enabled=1 relay_was_active=1
    systemctl is-enabled --quiet "${relay_service}" 2>/dev/null || relay_was_enabled=0
    systemctl is-active --quiet "${relay_service}" 2>/dev/null || relay_was_active=0

    msg_info "Updating ${APP} relay host (channel: ${installer_channel})"
    local relay_install_args=(relay host install --mode system --channel "${installer_channel}")
    if systemctl is-active --quiet "${relay_service}-updater.timer" 2>/dev/null; then
      relay_install_args+=(--auto-update)
    fi
    # A3: the bare reinstall resets the relay env to vendor defaults (verified live
    # on dev channel: it rewrites HAPPIER_SERVER_UI_DIR from the installer's managed
    # /var/lib/... bundle dir back to /opt/...). Re-pass the install-managed env so
    # the update preserves it — otherwise the freshly-refreshed UI bundle stops
    # being served after every update.
    if [[ "${ui_managed}" -eq 1 ]]; then
      relay_install_args+=(--env "HAPPIER_SERVER_UI_DIR=$(channel_ui_current_dir "${installer_channel}")")
    fi
    if [[ -f "${config_env_path}" ]]; then
      local _envk="" _envv=""
      for _envk in HAPPIER_SERVER_HOST PORT HAPPIER_PUBLIC_SERVER_URL HAPPIER_WEBAPP_URL; do
        _envv="$(grep -aE "^${_envk}=" "${config_env_path}" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
        # `if`, not `&&`: an empty value (e.g. the proxy URLs on a non-proxy install)
        # must not make the guard return non-zero under the update's errexit trap.
        if [[ -n "${_envv}" ]]; then
          relay_install_args+=(--env "${_envk}=${_envv}")
        fi
      done
    fi
    # Guard the reinstall: it runs under the ERR trap between the CLI self-update
    # and the daemon restart, so an unguarded failure would abort the update with
    # the daemon still on the old CLI. Warn and continue instead.
    local relay_install_rc=0
    "${cli_bin}" "${relay_install_args[@]}" || relay_install_rc=$?
    if [[ "${relay_install_rc}" -ne 0 ]]; then
      msg_warn "Relay host reinstall failed (rc=${relay_install_rc}); continuing with the existing relay unit"
    fi
    # Restore the captured autostart state, then restart only if it was running.
    if [[ "${relay_was_enabled}" -eq 0 ]]; then
      systemctl disable -q --now "${relay_service}" >/dev/null 2>&1 || true
    elif [[ "${relay_was_active}" -eq 1 ]]; then
      restart_happier_unit "${relay_service}"
    fi
    # Devbox: the relay restart above does not cycle the daemon, so a CLI self-update
    # leaves the running daemon on the old CLI. Restart it (no-op for server_only).
    if "${cli_bin}" daemon status >/dev/null 2>&1; then
      "${cli_bin}" daemon restart >/dev/null 2>&1 || true
    else
      local _daemon_unit
      _daemon_unit="$(find_happier_daemon_unit)"
      if [[ -n "${_daemon_unit}" ]]; then
        restart_happier_unit "${_daemon_unit}"
      fi
    fi
    msg_ok "Updated ${APP}"
    exit 0
  fi

  # Legacy from-source stack install
  if [[ -x "${HAPPIER_STACK_DEFAULT_BIN}" ]]; then
    local hstack_bin="${HAPPIER_STACK_DEFAULT_BIN}"
    local stack_home="${HAPPIER_STACK_DEFAULT_HOME}"
    local stack_env="${HAPPIER_STACK_DEFAULT_ENV}"
    local stack_label="${HAPPIER_STACK_DEFAULT_LABEL}"
    local workspace_dir=""

    resolve_hstack_layout "${hstack_bin}"
    [[ -n "${HSTACK_WHERE_HOME}" ]] && stack_home="${HSTACK_WHERE_HOME}"
    [[ -n "${HSTACK_WHERE_ENV}" ]] && stack_env="${HSTACK_WHERE_ENV}"
    [[ -n "${HSTACK_WHERE_LABEL}" ]] && stack_label="${HSTACK_WHERE_LABEL}"
    [[ -n "${HSTACK_WHERE_WORKSPACE}" ]] && workspace_dir="${HSTACK_WHERE_WORKSPACE}"

    if [[ -z "${workspace_dir}" ]]; then
      if [[ -d "${stack_home}/workspace/main" ]]; then
        workspace_dir="${stack_home}/workspace/main"
      elif [[ -d "${stack_home}/workspace" ]]; then
        workspace_dir="$(find "${stack_home}/workspace" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1 || true)"
      fi
    fi

    msg_warn "This Happier installation was created using setup-from-source."
    echo
    echo "Repo workspace:"
    if [[ -n "${workspace_dir}" ]]; then
      echo "  ${workspace_dir}"
    else
      echo "  (not detected) expected under: ${stack_home}/workspace/"
    fi
    echo
    echo "Manual update (advanced):"
    echo "  1) Enter the container and switch user:"
    echo "     pct enter <CTID>"
    echo "     su - happier"
    if [[ -n "${workspace_dir}" ]]; then
      echo "  2) Update the repo (fast-forward only):"
      echo "     cd \"${workspace_dir}\""
      echo "     git pull --ff-only"
    else
      echo "  2) Locate the repo and update it:"
      echo "     ls -la \"${stack_home}/workspace\""
      echo "     cd \"${stack_home}/workspace/<name>\""
      echo "     git pull --ff-only"
    fi
    echo "  3) Rebuild/restart:"
    echo "     ${hstack_bin} build --no-tauri   # only if you serve the UI"
    echo "     systemctl restart \"${stack_label}.service\"   # if autostart enabled"
    echo "     ${hstack_bin} start --restart    # if running manually"
    echo
    echo "Config file:"
    echo "  ${stack_env}"
    echo
    msg_ok "No automatic update was applied for setup-from-source installs."
    exit 0
  fi

  msg_error "No ${APP} installation found."
  exit 1
}

function app_questions() {
  local BACKTITLE="Proxmox VE Helper Scripts"

  # Honor pre-set env for EVERY knob: capture which were already provided so we
  # can skip their prompts and preserve the supplied values. Presetting all of
  # them yields a fully non-interactive install (build.func side: mode=default).
  local _preset_type="${HAPPIER_PVE_INSTALL_TYPE+x}" _preset_ui="${HAPPIER_PVE_SERVE_UI+x}"
  local _preset_autostart="${HAPPIER_PVE_AUTOSTART+x}" _preset_remote="${HAPPIER_PVE_REMOTE_ACCESS+x}"
  local _preset_auth="${HAPPIER_PVE_DAEMON_AUTH+x}"
  local _preset_channel="${HAPPIER_PVE_CHANNEL+x}${HAPPIER_PVE_HSTACK_CHANNEL+x}"
  local _preset_agents="${HAPPIER_PVE_INSTALL_AGENTS+x}" _preset_pat="${HAPPIER_PVE_GITHUB_PAT+x}" _preset_au="${HAPPIER_PVE_AUTO_UPDATE+x}"

  HAPPIER_PVE_INSTALL_TYPE="${HAPPIER_PVE_INSTALL_TYPE:-}"
  HAPPIER_PVE_SERVE_UI="${HAPPIER_PVE_SERVE_UI:-1}"
  HAPPIER_PVE_AUTOSTART="${HAPPIER_PVE_AUTOSTART:-1}"
  HAPPIER_PVE_REMOTE_ACCESS="${HAPPIER_PVE_REMOTE_ACCESS:-none}"
  HAPPIER_PVE_TAILSCALE_AUTHKEY="${HAPPIER_PVE_TAILSCALE_AUTHKEY:-}"
  HAPPIER_PVE_PUBLIC_URL="${HAPPIER_PVE_PUBLIC_URL:-}"
  HAPPIER_PVE_DAEMON_AUTH="${HAPPIER_PVE_DAEMON_AUTH:-0}"
  HAPPIER_PVE_CHANNEL="${HAPPIER_PVE_CHANNEL:-${HAPPIER_PVE_HSTACK_CHANNEL:-stable}}"
  HAPPIER_PVE_STACK_PACKAGE="${HAPPIER_PVE_STACK_PACKAGE:-${HAPPIER_PVE_HSTACK_PACKAGE:-}}"
  HAPPIER_PVE_INSTALL_AGENTS="${HAPPIER_PVE_INSTALL_AGENTS:-1}"
  HAPPIER_PVE_GITHUB_PAT="${HAPPIER_PVE_GITHUB_PAT:-}"
  HAPPIER_PVE_AUTO_UPDATE="${HAPPIER_PVE_AUTO_UPDATE:-0}"
  HAPPIER_PVE_AUTO_UPDATE_AT="${HAPPIER_PVE_AUTO_UPDATE_AT:-04:00}"

  if [[ -z "${_preset_type}" ]]; then
    HAPPIER_PVE_INSTALL_TYPE=$(
      whiptail --backtitle "${BACKTITLE}" --title "HAPPIER" --radiolist \
        "\nSelect installation type:\n" 12 72 2 \
        "devbox" "Dev box (server-light + daemon) (recommended)" ON \
        "server_only" "Server only (no daemon)" OFF \
        3>&1 1>&2 2>&3
    ) || exit_script
  fi
  case "${HAPPIER_PVE_INSTALL_TYPE}" in
    devbox | server_only) ;;
    *)
      msg_error "Invalid HAPPIER_PVE_INSTALL_TYPE='${HAPPIER_PVE_INSTALL_TYPE}'. Use: devbox | server_only."
      exit 1
      ;;
  esac

  if [[ -z "${_preset_ui}" ]]; then
    if (whiptail --backtitle "${BACKTITLE}" --title "HAPPIER" --yesno \
      "\nServe the built Happier web UI from this machine?\n\nNote: for remote access, the UI requires HTTPS (Tailscale Serve or your reverse proxy).\n" 12 72); then
      HAPPIER_PVE_SERVE_UI="1"
    else
      HAPPIER_PVE_SERVE_UI="0"
    fi
  fi

  if [[ -z "${_preset_autostart}" ]]; then
    if (whiptail --backtitle "${BACKTITLE}" --title "HAPPIER" --yesno \
      "\nEnable autostart at boot?\n\nThis installs a systemd system service inside the container.\n" 12 72); then
      HAPPIER_PVE_AUTOSTART="1"
    else
      HAPPIER_PVE_AUTOSTART="0"
    fi
  fi

  if [[ -n "${_preset_remote}" ]]; then
    case "${HAPPIER_PVE_REMOTE_ACCESS}" in
      tailscale | proxy | none) ;;
      *)
        msg_error "Invalid HAPPIER_PVE_REMOTE_ACCESS='${HAPPIER_PVE_REMOTE_ACCESS}'. Use: tailscale | proxy | none."
        exit 1
        ;;
    esac
    if [[ "${HAPPIER_PVE_REMOTE_ACCESS}" == "proxy" && -z "${HAPPIER_PVE_PUBLIC_URL}" ]]; then
      msg_error "HAPPIER_PVE_REMOTE_ACCESS=proxy requires HAPPIER_PVE_PUBLIC_URL."
      exit 1
    fi
  fi

  while [[ -z "${_preset_remote}" ]]; do
    HAPPIER_PVE_REMOTE_ACCESS=$(
      whiptail --backtitle "${BACKTITLE}" --title "HAPPIER" --radiolist \
        "\nServer URL for QR/deep links (choose how other devices will reach this server):\n" 16 72 3 \
        "tailscale" "Tailscale HTTPS URL (recommended; works from your phone)" ON \
        "proxy" "Custom HTTPS URL (reverse proxy; works from your phone)" OFF \
        "none" "LAN-only (HTTP; not reachable off-LAN)" OFF \
        3>&1 1>&2 2>&3
    ) || exit_script

    if [[ "${HAPPIER_PVE_REMOTE_ACCESS}" == "proxy" ]]; then
      HAPPIER_PVE_PUBLIC_URL=$(
        whiptail --backtitle "${BACKTITLE}" --title "CUSTOM HTTPS URL" --inputbox \
          "\nEnter the HTTPS URL of your reverse proxy.\n\nExample:\n  https://happier.example.com\n\nThis URL will be embedded in QR codes/deep links and must be reachable from your phone.\n" 18 72 \
          3>&1 1>&2 2>&3
      ) || exit_script
      break
    fi

    if [[ "${HAPPIER_PVE_REMOTE_ACCESS}" == "tailscale" ]]; then
      if (whiptail --backtitle "${BACKTITLE}" --title "TAILSCALE" --yesno \
        "\nProvide a Tailscale pre-auth key now?\n\nRecommended: use an ephemeral, one-time key.\n\nIf you skip this, the installer will still install Tailscale and you can run 'tailscale up' later inside the container.\n" 14 72); then
        HAPPIER_PVE_TAILSCALE_AUTHKEY=$(
          whiptail --backtitle "${BACKTITLE}" --title "TAILSCALE" --passwordbox \
            "\nPaste your Tailscale pre-auth key (optional; will not be saved).\n\nTip: leave blank or press Cancel to skip and enroll manually later.\n" 14 72 \
            3>&1 1>&2 2>&3
        ) || HAPPIER_PVE_TAILSCALE_AUTHKEY=""
      fi
      break
    fi

    # LAN-only. Confirm to reduce confusion around QR codes not working off-LAN.
    local lan_ui_note=""
    if [[ "${HAPPIER_PVE_SERVE_UI}" == "1" ]]; then
      lan_ui_note="\nIf you enabled serving the web UI, it will work only on your LAN/VPN.\nFor access from outside your LAN, you still need HTTPS (Tailscale Serve or a reverse proxy).\n"
    fi
    if (whiptail --backtitle "${BACKTITLE}" --title "LAN-ONLY (HTTP)" --yesno \
      "\nLAN-only mode will embed an HTTP LAN URL in QR/deep links (example: http://<container-lan-ip>:3005 by default).\n\nThis works only when your phone/laptop are on the same LAN/VPN.\n${lan_ui_note}\nContinue with LAN-only mode?\n" 20 72); then
      break
    fi
  done

  # The tailscale choice needs the TUN device regardless of how it was selected
  # (prompt or preset env).
  if [[ "${HAPPIER_PVE_REMOTE_ACCESS}" == "tailscale" ]]; then
    # shellcheck disable=SC2034 # consumed by build.func (enables the TUN device for the CT)
    var_tun="yes"
  fi

  # Offer to authenticate the daemon interactively during install (devbox + UI only).
  # When enabled, the installer shows a QR code (hstack auth login) at the end of setup.
  if [[ -z "${_preset_auth}" && "${HAPPIER_PVE_INSTALL_TYPE}" == "devbox" && "${HAPPIER_PVE_SERVE_UI}" == "1" ]]; then
    if (whiptail --backtitle "${BACKTITLE}" --title "DAEMON AUTH" --yesno \
      "\nAuthenticate the daemon during install?\n\nAfter setup completes, a QR code will appear.\nScan it with the Happier mobile app to authenticate the daemon.\n\nSelect No to skip and authenticate manually later.\n" 15 72); then
      HAPPIER_PVE_DAEMON_AUTH="1"
    else
      HAPPIER_PVE_DAEMON_AUTH="0"
    fi
  fi

  if [[ "${HAPPIER_PVE_INSTALL_TYPE}" == "devbox" ]]; then
    if [[ -z "${_preset_agents}" ]]; then
      if (whiptail --backtitle "${BACKTITLE}" --title "AGENT CLIs" --yesno \
        "\nInstall the claude and codex CLIs now?\n\nThe daemon needs them to run agent sessions. Choose No if you'll install them yourself.\n" 12 72); then
        HAPPIER_PVE_INSTALL_AGENTS="1"
      else
        HAPPIER_PVE_INSTALL_AGENTS="0"
      fi
    fi
    if [[ -z "${_preset_pat}" ]]; then
      HAPPIER_PVE_GITHUB_PAT=$(
        whiptail --backtitle "${BACKTITLE}" --title "DAEMON GITHUB PAT" --passwordbox \
          "\nOptional: GitHub Personal Access Token for the daemon's git operations.\n\nLeave blank or press Cancel to skip (you can add it later)." 12 72 3>&1 1>&2 2>&3
      ) || HAPPIER_PVE_GITHUB_PAT=""
    fi
  fi

  if [[ -z "${_preset_au}" ]]; then
    if (whiptail --backtitle "${BACKTITLE}" --title "AUTO-UPDATE" --yesno \
      "\nEnable automatic updates?\n\nInstalls Happier's built-in updater timer (signature-verified, atomic, health-checked, auto-rollback). Default: No.\n" 13 72 --defaultno); then
      HAPPIER_PVE_AUTO_UPDATE="1"
      HAPPIER_PVE_AUTO_UPDATE_AT=$(
        whiptail --backtitle "${BACKTITLE}" --title "AUTO-UPDATE TIME" --inputbox \
          "\nDaily update time (HH:MM, 24h).\n\nCancel keeps the default (04:00)." 12 60 "${HAPPIER_PVE_AUTO_UPDATE_AT}" 3>&1 1>&2 2>&3
      ) || HAPPIER_PVE_AUTO_UPDATE_AT="04:00"
    else
      HAPPIER_PVE_AUTO_UPDATE="0"
    fi
  fi

  if [[ -z "${_preset_channel}" ]]; then
    local _ch_stable="OFF" _ch_preview="OFF" _ch_dev="OFF"
    case "${HAPPIER_PVE_CHANNEL}" in
      stable) _ch_stable="ON" ;;
      preview) _ch_preview="ON" ;;
      dev) _ch_dev="ON" ;;
    esac
    HAPPIER_PVE_CHANNEL=$(
      whiptail --backtitle "${BACKTITLE}" --title "HAPPIER RELEASE CHANNEL" --radiolist \
        "\nChoose a release channel:\n\n- stable: production channel (NOTE: the hosted stable build has recently been failing fresh system installs — last checked 2026-07-17; prefer preview/dev or verify first)\n- preview: pre-release (newer, less tested)\n- dev: rolling/unstable; there is no hosted web UI unless you serve the UI locally\n" 20 72 3 \
        "stable" "Stable (see note)" "${_ch_stable}" \
        "preview" "Preview / pre-release" "${_ch_preview}" \
        "dev" "Dev / unstable" "${_ch_dev}" \
        3>&1 1>&2 2>&3
    ) || exit_script
  fi
  HAPPIER_PVE_CHANNEL="$(normalize_happier_channel "${HAPPIER_PVE_CHANNEL}")" || {
    msg_error "Invalid HAPPIER_PVE_CHANNEL='${HAPPIER_PVE_CHANNEL}'. Use: stable | preview | dev."
    exit 1
  }

  HAPPIER_PVE_STACK_PACKAGE="$(channel_default_stack_package "${HAPPIER_PVE_CHANNEL}" "${HAPPIER_PVE_STACK_PACKAGE}")"

  export HAPPIER_PVE_INSTALL_TYPE
  export HAPPIER_PVE_SERVE_UI
  export HAPPIER_PVE_AUTOSTART
  export HAPPIER_PVE_REMOTE_ACCESS
  export HAPPIER_PVE_TAILSCALE_AUTHKEY
  export HAPPIER_PVE_PUBLIC_URL
  export HAPPIER_PVE_DAEMON_AUTH
  export HAPPIER_PVE_CHANNEL
  export HAPPIER_PVE_STACK_PACKAGE
  export HAPPIER_PVE_HSTACK_CHANNEL="${HAPPIER_PVE_CHANNEL}"
  export HAPPIER_PVE_HSTACK_PACKAGE="${HAPPIER_PVE_STACK_PACKAGE}"
  export HAPPIER_PVE_INSTALL_AGENTS HAPPIER_PVE_GITHUB_PAT HAPPIER_PVE_AUTO_UPDATE HAPPIER_PVE_AUTO_UPDATE_AT
}

if command -v pveversion >/dev/null 2>&1; then
  app_questions
fi

start
build_container
description

msg_ok "Completed successfully!\n"
