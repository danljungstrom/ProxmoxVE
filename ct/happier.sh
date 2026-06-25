#!/usr/bin/env bash
INSTALLER_REPO="${INSTALLER_REPO:-happier-dev/ProxmoxVE}"
INSTALLER_REF="${INSTALLER_REF:-main}"
export INSTALLER_REPO INSTALLER_REF

BUILD_FUNC_URL="https://raw.githubusercontent.com/${INSTALLER_REPO}/${INSTALLER_REF}/misc/build.func"
BUILD_FUNC="$(curl -fsSL "${BUILD_FUNC_URL}")" || {
  echo "Failed to download build.func from: ${BUILD_FUNC_URL}" >&2
  exit 1
}
if [[ -z "${BUILD_FUNC//[[:space:]]/}" ]]; then
  echo "Downloaded build.func is empty: ${BUILD_FUNC_URL}" >&2
  exit 1
fi
source /dev/stdin <<<"${BUILD_FUNC}"
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

header_info "$APP"
variables
color
catch_errors

normalize_happier_channel() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | xargs)" in
    ""|stable) printf '%s' "stable" ;;
    preview) printf '%s' "preview" ;;
    dev|publicdev) printf '%s' "dev" ;;
    *) return 1 ;;
  esac
}

channel_cli_name() {
  case "$1" in
    stable) printf '%s' "happier" ;;
    preview) printf '%s' "hprev" ;;
    dev) printf '%s' "hdev" ;;
    *) return 1 ;;
  esac
}

channel_suffix() {
  case "$1" in
    stable) printf '%s' "" ;;
    preview) printf '%s' "-preview" ;;
    dev) printf '%s' "-dev" ;;
    *) return 1 ;;
  esac
}

channel_config_env_path() {
  local suffix=""
  suffix="$(channel_suffix "$1")" || return 1
  printf '%s' "/etc/happier${suffix}/server.env"
}

channel_state_path() {
  local suffix=""
  suffix="$(channel_suffix "$1")" || return 1
  printf '%s' "/opt/happier${suffix}/self-host-state.json"
}

channel_ui_current_dir() {
  local suffix=""
  suffix="$(channel_suffix "$1")" || return 1
  printf '%s' "/var/lib/happier${suffix}/ui-web/current"
}

ui_release_tags_for_channel() {
  case "$1" in
    stable) printf '%s\n' "ui-web-stable" ;;
    preview) printf '%s\n' "ui-web-preview" "ui-web-stable" ;;
    dev) printf '%s\n' "ui-web-dev" "ui-web-preview" "ui-web-stable" ;;
    *) return 1 ;;
  esac
}

happier_github_curl() {
  local mode="$1"
  local url="$2"
  local destination="${3:-}"
  local config_path=""
  local status=0

  if [[ -n "${HAPPIER_GITHUB_TOKEN:-}" ]]; then
    config_path="$(mktemp)"
    chmod 600 "${config_path}" >/dev/null 2>&1 || true
    {
      printf '%s\n' "header = \"Authorization: Bearer ${HAPPIER_GITHUB_TOKEN}\""
      printf '%s\n' 'header = "Accept: application/vnd.github+json"'
      printf '%s\n' 'header = "X-GitHub-Api-Version: 2022-11-28"'
    } >"${config_path}"
  fi

  if [[ "${mode}" == "stdout" ]]; then
    if [[ -n "${config_path}" ]]; then
      curl -fsSL --config "${config_path}" "${url}"
      status=$?
    else
      curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${url}"
      status=$?
    fi
  else
    if [[ -z "${destination}" ]]; then
      msg_error "Destination path is required for Happier GitHub downloads."
      [[ -n "${config_path}" ]] && rm -f "${config_path}"
      return 1
    fi
    if [[ -n "${config_path}" ]]; then
      curl -fsSL --config "${config_path}" "${url}" -o "${destination}"
      status=$?
    else
      curl -fsSL "${url}" -o "${destination}"
      status=$?
    fi
  fi

  [[ -n "${config_path}" ]] && rm -f "${config_path}"
  return "${status}"
}

resolve_happier_release_json_for_tags() {
  local release_repo="$1"
  shift
  local tag=""
  local api_url=""
  for tag in "$@"; do
    [[ -z "${tag}" ]] && continue
    api_url="https://api.github.com/repos/${release_repo}/releases/tags/${tag}"
    if happier_github_curl stdout "${api_url}"; then
      return 0
    fi
  done
  return 1
}

resolve_ui_extract_root() {
  local extract_dir="$1"
  if [[ -f "${extract_dir}/index.html" ]]; then
    printf '%s' "${extract_dir}"
    return 0
  fi
  local index_path=""
  index_path="$(find "${extract_dir}" -mindepth 1 -maxdepth 2 -type f -name index.html 2>/dev/null | head -n 1 || true)"
  if [[ -n "${index_path}" ]]; then
    dirname "${index_path}"
    return 0
  fi
  return 1
}

resolve_installed_cli_for_channel() {
  local cli_name=""
  cli_name="$(channel_cli_name "$1")" || return 1
  command -v "${cli_name}" 2>/dev/null || true
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  refresh_managed_ui_bundle() {
    local channel="$1"
    local ui_current_dir=""
    ui_current_dir="$(channel_ui_current_dir "${channel}")"
    local ui_versions_dir
    ui_versions_dir="$(dirname "${ui_current_dir}")/versions"
    local release_repo="${HAPPIER_GITHUB_REPO:-happier-dev/happier}"
    local minisign_pubkey="${HAPPIER_MINISIGN_PUBKEY:-$(cat <<'EOF'
untrusted comment: minisign public key 91AE28177BF6E43C
RWQ85PZ7FyiukYbL3qv/bKnwgbT68wLVzotapeMFIb8n+c7pBQ7U8W2t
EOF
)}"
    local temp_dir=""
    temp_dir="$(mktemp -d)"
    local release_json="${temp_dir}/release.json"
    local checksums_path="${temp_dir}/checksums-happier-ui-web.txt"
    local sig_path="${checksums_path}.minisig"
    local archive_path="${temp_dir}/happier-ui-web.tar.gz"
    local pubkey_path="${temp_dir}/minisign.pub"

    if ! command -v minisign >/dev/null 2>&1; then
      msg_error "minisign is required to refresh the Happier UI bundle."
      rm -rf "${temp_dir}"
      exit 1
    fi

    if ! resolve_happier_release_json_for_tags "${release_repo}" $(ui_release_tags_for_channel "${channel}") >"${release_json}"; then
      msg_error "Unable to resolve a Happier UI release for channel ${channel}."
      rm -rf "${temp_dir}"
      exit 1
    fi

    local checksums_name=""
    checksums_name="$(jq -r '.assets[].name' "${release_json}" | grep -E '^checksums-happier-ui-web-v.+\.txt$' | head -n 1 || true)"
    if [[ -z "${checksums_name}" ]]; then
      msg_error "Unable to find Happier UI checksum assets."
      rm -rf "${temp_dir}"
      exit 1
    fi

    local version="${checksums_name#checksums-happier-ui-web-v}"
    version="${version%.txt}"
    local archive_name="happier-ui-web-v${version}-web-any.tar.gz"
    local checksums_url=""
    local sig_url=""
    local archive_url=""
    checksums_url="$(jq -r --arg name "${checksums_name}" '.assets[] | select(.name == $name) | .browser_download_url' "${release_json}" | head -n 1)"
    sig_url="$(jq -r --arg name "${checksums_name}.minisig" '.assets[] | select(.name == $name) | .browser_download_url' "${release_json}" | head -n 1)"
    archive_url="$(jq -r --arg name "${archive_name}" '.assets[] | select(.name == $name) | .browser_download_url' "${release_json}" | head -n 1)"
    [[ -z "${checksums_url}" || -z "${sig_url}" || -z "${archive_url}" ]] && {
      msg_error "Unable to resolve Happier UI bundle assets."
      rm -rf "${temp_dir}"
      exit 1
    }

    download_file "${checksums_url}" "${checksums_path}" 3 true || {
      msg_error "Unable to download Happier UI checksum list."
      rm -rf "${temp_dir}"
      exit 1
    }
    download_file "${sig_url}" "${sig_path}" 3 true || {
      msg_error "Unable to download Happier UI minisign signature."
      rm -rf "${temp_dir}"
      exit 1
    }
    download_file "${archive_url}" "${archive_path}" 3 true || {
      msg_error "Unable to download Happier UI archive."
      rm -rf "${temp_dir}"
      exit 1
    }
    printf '%s\n' "${minisign_pubkey}" >"${pubkey_path}"
    minisign -Vm "${checksums_path}" -x "${sig_path}" -p "${pubkey_path}" >/dev/null 2>&1 || {
      msg_error "Happier UI checksum signature verification failed."
      rm -rf "${temp_dir}"
      exit 1
    }
    (
      cd "${temp_dir}" || exit 1
      grep "  ${archive_name}\$" "${checksums_path}" | sha256sum -c - >/dev/null 2>&1
    ) || {
      msg_error "Happier UI archive checksum verification failed."
      rm -rf "${temp_dir}"
      exit 1
    }

    local extract_dir="${temp_dir}/extract"
    mkdir -p "${extract_dir}"
    tar -xzf "${archive_path}" -C "${extract_dir}"
    local artifact_root=""
    artifact_root="$(resolve_ui_extract_root "${extract_dir}" || true)"
    if [[ -z "${artifact_root}" || ! -f "${artifact_root}/index.html" ]]; then
      msg_error "Extracted Happier UI bundle is missing index.html."
      rm -rf "${temp_dir}"
      exit 1
    fi

    local version_dir="${ui_versions_dir}/happier-ui-web-${version}"
    mkdir -p "${ui_versions_dir}"
    rm -rf "${version_dir}"
    mkdir -p "${version_dir}"
    cp -a "${artifact_root}/." "${version_dir}/"
    ln -sfn "${version_dir}" "${ui_current_dir}"
    rm -rf "${temp_dir}"
  }

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
    cli_bin="$(resolve_installed_cli_for_channel "${installer_channel}")"
    if [[ -z "${cli_bin}" ]]; then
      msg_error "No channel-matched Happier CLI was found. Try reinstalling the Proxmox container."
      exit 1
    fi

    if [[ -f "${config_env_path}" ]] && grep -q '^HAPPIER_SERVER_UI_DIR=' "${config_env_path}"; then
      msg_info "Refreshing ${APP} web UI bundle (channel: ${installer_channel})"
      refresh_managed_ui_bundle "${installer_channel}"
      msg_ok "Refreshed ${APP} web UI bundle"
    fi

    msg_info "Updating ${APP} CLI (channel: ${installer_channel})"
    "${cli_bin}" self update --channel="${installer_channel}" >/dev/null 2>&1 || true
    cli_bin="$(resolve_installed_cli_for_channel "${installer_channel}")"
    msg_ok "Updated ${APP} CLI"

    msg_info "Updating ${APP} relay host (channel: ${installer_channel})"
    "${cli_bin}" relay host install --mode system --channel "${installer_channel}"
    systemctl restart 'happier-daemon.*.service' >/dev/null 2>&1 || true
    msg_ok "Updated ${APP}"
    exit
  fi

  # Legacy from-source stack install
  if [[ -x /home/happier/.happier-stack/bin/hstack ]]; then
    local hstack_bin="/home/happier/.happier-stack/bin/hstack"
    local where_json=""
    local stack_home="/home/happier/.happier-stack"
    local stack_env="/home/happier/.happier/stacks/main/env"
    local stack_label="dev.happier.stack"
    local workspace_dir=""

    where_json="$(sudo -u happier -H "${hstack_bin}" where --json 2>/dev/null || true)"
    if [[ -n "${where_json}" ]] && command -v jq >/dev/null 2>&1; then
      _home="$(printf '%s' "${where_json}" | jq -r '.homeDir // empty' 2>/dev/null || true)"
      _env="$(printf '%s' "${where_json}" | jq -r '.envFiles.main.path // empty' 2>/dev/null || true)"
      _label="$(printf '%s' "${where_json}" | jq -r '.stack.label // empty' 2>/dev/null || true)"
      _ws="$(printf '%s' "${where_json}" | jq -r '.workspaceDir // .workspace.dir // .workspace.path // empty' 2>/dev/null || true)"
      [[ -n "${_home}" ]] && stack_home="${_home}"
      [[ -n "${_env}" ]] && stack_env="${_env}"
      [[ -n "${_label}" ]] && stack_label="${_label}"
      [[ -n "${_ws}" ]] && workspace_dir="${_ws}"
    fi

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
  exit
}

function app_questions() {
  local BACKTITLE="Proxmox VE Helper Scripts"

  HAPPIER_PVE_INSTALL_TYPE=""
  HAPPIER_PVE_SERVE_UI="1"
  HAPPIER_PVE_AUTOSTART="1"
  HAPPIER_PVE_REMOTE_ACCESS="none"
  HAPPIER_PVE_TAILSCALE_AUTHKEY=""
  HAPPIER_PVE_PUBLIC_URL=""
  HAPPIER_PVE_CHANNEL="${HAPPIER_PVE_CHANNEL:-${HAPPIER_PVE_HSTACK_CHANNEL:-stable}}"
  HAPPIER_PVE_STACK_PACKAGE="${HAPPIER_PVE_STACK_PACKAGE:-${HAPPIER_PVE_HSTACK_PACKAGE:-}}"

  HAPPIER_PVE_INSTALL_TYPE=$(
    whiptail --backtitle "$BACKTITLE" --title "HAPPIER" --radiolist \
      "\nSelect installation type:\n" 12 72 2 \
      "devbox" "Dev box (server-light + daemon) (recommended)" ON \
      "server_only" "Server only (no daemon)" OFF \
      3>&1 1>&2 2>&3
  ) || exit_script

  if (whiptail --backtitle "$BACKTITLE" --title "HAPPIER" --yesno \
    "\nServe the built Happier web UI from this machine?\n\nNote: for remote access, the UI requires HTTPS (Tailscale Serve or your reverse proxy).\n" 12 72); then
    HAPPIER_PVE_SERVE_UI="1"
  else
    HAPPIER_PVE_SERVE_UI="0"
  fi

  if (whiptail --backtitle "$BACKTITLE" --title "HAPPIER" --yesno \
    "\nEnable autostart at boot?\n\nThis installs a systemd system service inside the container.\n" 12 72); then
    HAPPIER_PVE_AUTOSTART="1"
  else
    HAPPIER_PVE_AUTOSTART="0"
  fi

  while true; do
    HAPPIER_PVE_REMOTE_ACCESS=$(
      whiptail --backtitle "$BACKTITLE" --title "HAPPIER" --radiolist \
        "\nServer URL for QR/deep links (choose how other devices will reach this server):\n" 16 72 3 \
        "tailscale" "Tailscale HTTPS URL (recommended; works from your phone)" ON \
        "proxy" "Custom HTTPS URL (reverse proxy; works from your phone)" OFF \
        "none" "LAN-only (HTTP; not reachable off-LAN)" OFF \
        3>&1 1>&2 2>&3
    ) || exit_script

    if [[ "$HAPPIER_PVE_REMOTE_ACCESS" == "proxy" ]]; then
      HAPPIER_PVE_PUBLIC_URL=$(
        whiptail --backtitle "$BACKTITLE" --title "CUSTOM HTTPS URL" --inputbox \
          "\nEnter the HTTPS URL of your reverse proxy.\n\nExample:\n  https://happier.example.com\n\nThis URL will be embedded in QR codes/deep links and must be reachable from your phone.\n" 18 72 \
          3>&1 1>&2 2>&3
      ) || exit_script
      break
    fi

    if [[ "$HAPPIER_PVE_REMOTE_ACCESS" == "tailscale" ]]; then
      var_tun="yes"
      if (whiptail --backtitle "$BACKTITLE" --title "TAILSCALE" --yesno \
        "\nProvide a Tailscale pre-auth key now?\n\nRecommended: use an ephemeral, one-time key.\n\nIf you skip this, the installer will still install Tailscale and you can run 'tailscale up' later inside the container.\n" 14 72); then
        HAPPIER_PVE_TAILSCALE_AUTHKEY=$(
          whiptail --backtitle "$BACKTITLE" --title "TAILSCALE" --passwordbox \
            "\nPaste your Tailscale pre-auth key (optional; will not be saved).\n\nTip: leave blank to skip and enroll manually later.\n" 14 72 \
            3>&1 1>&2 2>&3
        ) || exit_script
      fi
      break
    fi

    # LAN-only. Confirm to reduce confusion around QR codes not working off-LAN.
    local lan_ui_note=""
    if [[ "${HAPPIER_PVE_SERVE_UI}" == "1" ]]; then
      lan_ui_note="\nIf you enabled serving the web UI, it will work only on your LAN/VPN.\nFor access from outside your LAN, you still need HTTPS (Tailscale Serve or a reverse proxy).\n"
    fi
    if (whiptail --backtitle "$BACKTITLE" --title "LAN-ONLY (HTTP)" --yesno \
      "\nLAN-only mode will embed an HTTP LAN URL in QR/deep links (example: http://<container-lan-ip>:3005 by default).\n\nThis works only when your phone/laptop are on the same LAN/VPN.\n${lan_ui_note}\nContinue with LAN-only mode?\n" 20 72); then
      break
    fi
  done

  HAPPIER_PVE_CHANNEL=$(
    whiptail --backtitle "$BACKTITLE" --title "HAPPIER RELEASE CHANNEL" --radiolist \
      "\nChoose a release channel:\n\n- stable: recommended for production\n- preview: pre-release (newer, less tested)\n- dev: rolling/unstable; there is no hosted web UI unless you serve the UI locally\n" 20 72 3 \
      "stable" "Stable (recommended)" $([[ "${HAPPIER_PVE_CHANNEL}" == "stable" ]] && echo ON || echo OFF) \
      "preview" "Preview / pre-release" $([[ "${HAPPIER_PVE_CHANNEL}" == "preview" ]] && echo ON || echo OFF) \
      "dev" "Dev / unstable" $([[ "${HAPPIER_PVE_CHANNEL}" == "dev" ]] && echo ON || echo OFF) \
      3>&1 1>&2 2>&3
  ) || exit_script

  if [[ -z "${HAPPIER_PVE_STACK_PACKAGE}" ]]; then
    if [[ "${HAPPIER_PVE_CHANNEL}" == "preview" ]]; then
      HAPPIER_PVE_STACK_PACKAGE="@happier-dev/stack@next"
    else
      HAPPIER_PVE_STACK_PACKAGE="@happier-dev/stack@latest"
    fi
  fi

  export HAPPIER_PVE_INSTALL_TYPE
  export HAPPIER_PVE_SERVE_UI
  export HAPPIER_PVE_AUTOSTART
  export HAPPIER_PVE_REMOTE_ACCESS
  export HAPPIER_PVE_TAILSCALE_AUTHKEY
  export HAPPIER_PVE_PUBLIC_URL
  export HAPPIER_PVE_CHANNEL
  export HAPPIER_PVE_STACK_PACKAGE
  export HAPPIER_PVE_HSTACK_CHANNEL="${HAPPIER_PVE_CHANNEL}"
  export HAPPIER_PVE_HSTACK_PACKAGE="${HAPPIER_PVE_STACK_PACKAGE}"
}

if command -v pveversion >/dev/null 2>&1; then
  app_questions
fi

start
build_container
description

msg_ok "Completed successfully!\n"
