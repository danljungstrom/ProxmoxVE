#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: happier-dev
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://happier.dev

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"

# Used by community-scripts helpers (e.g. motd_ssh in misc/install.func).
APP="Happier"
app="${app:-happier}"
APPLICATION="Happier"
SSH_ROOT="${SSH_ROOT:-no}"
PASSWORD="${PASSWORD:-}"
SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY:-}"

color
verb_ip6
catch_errors
setting_up_container
network_check

wait_for_apt_locks() {
  if ! command -v fuser >/dev/null 2>&1; then
    return 0
  fi
  local waited_s=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
    sleep 3
    waited_s=$((waited_s + 3))
    if ((waited_s >= 300)); then
      msg_error "apt is busy (locks held > ${waited_s}s). Try again in a minute."
      exit 1
    fi
  done
}

msg_info "Waiting for apt locks (if any)"
wait_for_apt_locks
msg_ok "apt ready"

update_os

INSTALL_TYPE="${HAPPIER_PVE_INSTALL_TYPE:-devbox}"      # devbox | server_only
SERVE_UI="${HAPPIER_PVE_SERVE_UI:-1}"                  # 1 | 0
AUTOSTART="${HAPPIER_PVE_AUTOSTART:-1}"                # 1 | 0
REMOTE_ACCESS="${HAPPIER_PVE_REMOTE_ACCESS:-none}"     # none | proxy | tailscale
INSTALL_METHOD_RAW="${HAPPIER_PVE_INSTALL_METHOD:-installers}" # installers | from_source (aliases: auto|selfhost|legacy)
TAILSCALE_AUTHKEY="${HAPPIER_PVE_TAILSCALE_AUTHKEY:-}" # optional
PUBLIC_URL_RAW="${HAPPIER_PVE_PUBLIC_URL:-}"           # required when REMOTE_ACCESS=proxy
HAPPIER_CHANNEL_RAW="${HAPPIER_PVE_CHANNEL:-${HAPPIER_PVE_HSTACK_CHANNEL:-stable}}" # stable | preview | dev
STACK_PACKAGE_RAW="${HAPPIER_PVE_STACK_PACKAGE:-${HAPPIER_PVE_HSTACK_PACKAGE:-}}"    # e.g. @happier-dev/stack@latest
SERVER_PORT_RAW="${HAPPIER_PVE_SERVER_PORT:-}"                                       # optional explicit PORT override
HAPPIER_RELEASE_GITHUB_REPO="${HAPPIER_GITHUB_REPO:-happier-dev/happier}"
TAILSCALE_ENABLE_SERVE="0"
TAILSCALE_HTTPS_URL=""
TAILSCALE_NEEDS_LOGIN="0"
TAILSCALE_AUTH_INVALID="0"
TAILSCALE_AUTH_URL=""
HAPPIER_CLI_BIN=""
HAPPIER_CLI_NAME=""
HAPPIER_SERVER_PORT="${SERVER_PORT_RAW:-3005}"
DEFAULT_MINISIGN_PUBKEY="$(cat <<'EOF'
untrusted comment: minisign public key 91AE28177BF6E43C
RWQ85PZ7FyiukYbL3qv/bKnwgbT68wLVzotapeMFIb8n+c7pBQ7U8W2t
EOF
)"
MINISIGN_PUBKEY="${HAPPIER_MINISIGN_PUBKEY:-${DEFAULT_MINISIGN_PUBKEY}}"

normalize_url_no_trailing_slash() {
  local v
  v="$(printf '%s' "$1" | tr -d '\r' | xargs || true)"
  v="${v%/}"
  while [[ "$v" == */ ]]; do v="${v%/}"; done
  printf '%s' "$v"
}

normalize_https_public_url_or_empty() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import sys
from urllib.parse import urlsplit

raw = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
if not raw:
  sys.exit(0)

u = urlsplit(raw)
if u.scheme != "https":
  sys.exit(0)
if not u.netloc:
  sys.exit(0)
if u.username or u.password:
  sys.exit(0)
host = u.hostname
if not host:
  sys.exit(0)
port = f":{u.port}" if u.port else ""
path = u.path or ""

# Drop query/hash and strip trailing slashes for consistency.
out = f"https://{host}{port}{path}".rstrip("/")
print(out, end="")
PY
}

normalize_happier_channel() {
  local raw
  raw="$(printf '%s' "$1" | tr -d '\r' | xargs | tr '[:upper:]' '[:lower:]')"
  case "${raw}" in
    ""|stable)
      printf '%s' "stable"
      ;;
    preview)
      printf '%s' "preview"
      ;;
    dev|publicdev)
      printf '%s' "dev"
      ;;
    *)
      return 1
      ;;
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

channel_relay_service_name() {
  local suffix=""
  suffix="$(channel_suffix "$1")" || return 1
  printf '%s' "happier-server${suffix}"
}

channel_config_env_path() {
  local suffix=""
  suffix="$(channel_suffix "$1")" || return 1
  printf '%s' "/etc/happier${suffix}/server.env"
}

channel_data_dir() {
  local suffix=""
  suffix="$(channel_suffix "$1")" || return 1
  printf '%s' "/var/lib/happier${suffix}"
}

channel_ui_current_dir() {
  printf '%s' "$(channel_data_dir "$1")/ui-web/current"
}

channel_hosted_webapp_url() {
  case "$1" in
    stable|preview) printf '%s' "https://app.happier.dev" ;;
    dev) printf '%s' "" ;;
    *) return 1 ;;
  esac
}

extract_https_url_from_text() {
  awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^https:\/\//) {
          gsub(/\r/, "", $i)
          print $i
          exit
        }
      }
    }
  '
}

detect_tailscale_https_url() {
  local detected=""
  if [[ -n "${HSTACK_BIN:-}" && -x "${HSTACK_BIN}" ]] && id happier >/dev/null 2>&1; then
    detected="$(sudo -u happier -H "${HSTACK_BIN}" tailscale url 2>/dev/null | extract_https_url_from_text || true)"
    if [[ "${detected}" == https://* ]]; then
      normalize_url_no_trailing_slash "${detected}"
      return 0
    fi
  fi

  if [[ -n "${TAILSCALE_BIN:-}" && -x "${TAILSCALE_BIN}" ]]; then
    detected="$("${TAILSCALE_BIN}" serve status 2>/dev/null | extract_https_url_from_text || true)"
  else
    detected="$(tailscale serve status 2>/dev/null | extract_https_url_from_text || true)"
  fi
  if [[ "${detected}" == https://* ]]; then
    normalize_url_no_trailing_slash "${detected}"
    return 0
  fi
  return 1
}

resolve_tailscale_https_url_with_retries() {
  local attempts="${1:-10}"
  local sleep_s="${2:-2}"
  local i=1
  local detected=""
  while (( i <= attempts )); do
    detected="$(detect_tailscale_https_url || true)"
    if [[ "${detected}" == https://* ]]; then
      printf '%s' "${detected}"
      return 0
    fi
    sleep "${sleep_s}"
    i=$((i + 1))
  done
  return 1
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

install_managed_ui_bundle() {
  local channel="$1"
  local ui_root
  ui_root="$(channel_data_dir "${channel}")/ui-web"
  local ui_versions_dir="${ui_root}/versions"
  local ui_current_dir="${ui_root}/current"
  local release_repo="${HAPPIER_RELEASE_GITHUB_REPO:-happier-dev/happier}"
  local temp_dir=""
  temp_dir="$(mktemp -d)"
  local release_json="${temp_dir}/release.json"
  local checksums_path="${temp_dir}/checksums-happier-ui-web.txt"
  local sig_path="${checksums_path}.minisig"
  local archive_path="${temp_dir}/happier-ui-web.tar.gz"
  local pubkey_path="${temp_dir}/minisign.pub"

  if ! command -v minisign >/dev/null 2>&1; then
    msg_error "minisign is required to install the Happier UI bundle."
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
  if [[ -z "${checksums_url}" || -z "${sig_url}" || -z "${archive_url}" ]]; then
    msg_error "Unable to resolve Happier UI bundle assets for version ${version}."
    rm -rf "${temp_dir}"
    exit 1
  fi

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
  printf '%s\n' "${MINISIGN_PUBKEY}" >"${pubkey_path}"
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
  printf '%s' "${ui_current_dir}"
}

resolve_installed_cli_path_or_fail() {
  local cli_name
  cli_name="$(channel_cli_name "${HAPPIER_CHANNEL}")" || {
    msg_error "Invalid Happier channel: ${HAPPIER_CHANNEL}"
    exit 1
  }
  local candidate=""
  candidate="$(command -v "${cli_name}" 2>/dev/null || true)"
  if [[ -z "${candidate}" && -x "/opt/happier/cli/bin/${cli_name}" ]]; then
    candidate="/opt/happier/cli/bin/${cli_name}"
  fi
  if [[ -z "${candidate}" || ! -x "${candidate}" ]]; then
    msg_error "Unable to resolve the installed ${cli_name} CLI."
    exit 1
  fi
  HAPPIER_CLI_NAME="${cli_name}"
  HAPPIER_CLI_BIN="${candidate}"
}

INSTALL_METHOD="$(printf '%s' "${INSTALL_METHOD_RAW}" | tr -d '\r' | xargs | tr '[:upper:]' '[:lower:]')"
case "${INSTALL_METHOD}" in
  ""|auto|installers|installer|selfhost|self-host)
    INSTALL_METHOD="installers"
    ;;
  from_source|from-source|source|setup|setup-from-source|legacy)
    INSTALL_METHOD="from_source"
    ;;
  *)
    msg_error "Invalid HAPPIER_PVE_INSTALL_METHOD=${INSTALL_METHOD_RAW}. Use: installers | from_source."
    exit 1
    ;;
esac

PUBLIC_URL="$(normalize_url_no_trailing_slash "$PUBLIC_URL_RAW")"
if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
  if [[ -z "${PUBLIC_URL}" ]]; then
    msg_error "REMOTE_ACCESS=proxy requires HAPPIER_PVE_PUBLIC_URL (public HTTPS URL)."
    exit 1
  fi
  PUBLIC_URL_NORMALIZED="$(normalize_https_public_url_or_empty "${PUBLIC_URL}")"
  if [[ -z "${PUBLIC_URL_NORMALIZED}" ]]; then
    msg_error "HAPPIER_PVE_PUBLIC_URL must be a valid https:// URL (no credentials, no query/hash)."
    msg_error "Got: ${PUBLIC_URL}"
    exit 1
  fi
  PUBLIC_URL="${PUBLIC_URL_NORMALIZED}"
fi

HAPPIER_CHANNEL="$(normalize_happier_channel "${HAPPIER_CHANNEL_RAW}")" || {
  msg_error "Invalid HAPPIER release channel: ${HAPPIER_CHANNEL_RAW}. Use stable | preview | dev."
  exit 1
}
STACK_PACKAGE="$(printf '%s' "${STACK_PACKAGE_RAW}" | tr -d '\r' | xargs)"
if [[ -z "${STACK_PACKAGE}" ]]; then
  if [[ "${HAPPIER_CHANNEL}" == "preview" ]]; then
    STACK_PACKAGE="@happier-dev/stack@next"
  else
    STACK_PACKAGE="@happier-dev/stack@latest"
  fi
fi
if [[ "${STACK_PACKAGE}" == "@happier-dev/stack@preview" ]]; then
  # Back-compat: "preview" maps to the npm dist-tag "next".
  STACK_PACKAGE="@happier-dev/stack@next"
fi
if [[ -z "${STACK_PACKAGE}" ]]; then
  msg_error "Stack package spec is empty. Set HAPPIER_PVE_STACK_PACKAGE or HAPPIER_PVE_CHANNEL."
  exit 1
fi

if [[ "${HAPPIER_CHANNEL}" == "dev" && "${SERVE_UI}" != "1" ]]; then
  msg_info "Dev channel selected without local UI"
  msg_info "The dev lane does not have a hosted web UI. Mobile and CLI flows still work, but web onboarding links will be limited."
  msg_ok "Continuing with dev lane"
fi

msg_info "Installing Dependencies"
APT_DEPS=(
  ca-certificates
  curl
  gnupg
  jq
  minisign
  python3
)
if [[ "${INSTALL_METHOD}" == "from_source" ]]; then
  APT_DEPS+=(
    git
    build-essential
  )
fi
$STD apt-get install -y "${APT_DEPS[@]}"
msg_ok "Installed Dependencies"

if [[ "${INSTALL_METHOD}" == "from_source" ]]; then
  msg_info "Installing Node.js"
  NODE_VERSION="24" setup_nodejs
  msg_ok "Installed Node.js"

  msg_info "Enabling Corepack (yarn)"
  if ! command -v corepack >/dev/null 2>&1; then
    msg_error "corepack not found (required for yarn)."
    exit 1
  fi
  $STD corepack enable
  msg_ok "Enabled Corepack"
fi

msg_info "Creating user"
if ! id happier &>/dev/null; then
  $STD useradd -m -s /bin/bash happier
fi
msg_ok "User ready"

SETUP_BIND="loopback"
SERVER_HOST="127.0.0.1"
if [[ "${REMOTE_ACCESS}" == "proxy" || "${REMOTE_ACCESS}" == "none" ]]; then
  SETUP_BIND="lan"
  SERVER_HOST="0.0.0.0"
fi

install_happier_cli_binary() {
  msg_info "Installing Happier CLI — channel: ${HAPPIER_CHANNEL}"
  HAPPIER_CHANNEL="${HAPPIER_CHANNEL}" \
    HAPPIER_PRODUCT="cli" \
    HAPPIER_INSTALL_DIR="/opt/happier/cli" \
    HAPPIER_BIN_DIR="/usr/local/bin" \
    HAPPIER_WITH_DAEMON="0" \
    HAPPIER_NO_PATH_UPDATE="1" \
    HAPPIER_NONINTERACTIVE="1" \
    curl -fsSL "https://happier.dev/install" | $STD bash -s -- --channel "${HAPPIER_CHANNEL}"

  resolve_installed_cli_path_or_fail
  msg_ok "Installed Happier CLI"
}

install_devbox_cli_compat_wrapper() {
  if [[ "${HAPPIER_CHANNEL}" == "stable" ]]; then
    return 0
  fi
  local wrapper_dir="/home/happier/.local/bin"
  local wrapper_path="${wrapper_dir}/happier"
  mkdir -p "${wrapper_dir}"
  cat >"${wrapper_path}" <<EOF
#!/usr/bin/env bash
exec "${HAPPIER_CLI_BIN}" "\$@"
EOF
  chmod +x "${wrapper_path}"
  chown -R happier:happier "/home/happier/.local"
  if ! grep -Fq 'export PATH="$HOME/.local/bin:$PATH"' /home/happier/.profile 2>/dev/null; then
    printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >>/home/happier/.profile
    chown happier:happier /home/happier/.profile
  fi
}

install_managed_relay_runtime() {
  get_lxc_ip

  local relay_args=(relay host install --mode system --channel "${HAPPIER_CHANNEL}")
  relay_args+=(--env "HAPPIER_SERVER_HOST=${SERVER_HOST}")
  if [[ -n "${SERVER_PORT_RAW}" ]]; then
    relay_args+=(--env "PORT=${HAPPIER_SERVER_PORT}")
  fi
  if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
    relay_args+=(--env "HAPPIER_PUBLIC_SERVER_URL=${PUBLIC_URL}")
  fi

  local ui_current_dir=""
  if [[ "${SERVE_UI}" == "1" ]]; then
    msg_info "Installing Happier web UI bundle"
    ui_current_dir="$(install_managed_ui_bundle "${HAPPIER_CHANNEL}")"
    relay_args+=(--env "HAPPIER_SERVER_UI_DIR=${ui_current_dir}")
    if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
      relay_args+=(--env "HAPPIER_WEBAPP_URL=${PUBLIC_URL}")
    fi
    msg_ok "Installed Happier web UI bundle"
  fi

  msg_info "Installing Happier relay host"
  $STD "${HAPPIER_CLI_BIN}" "${relay_args[@]}" </dev/null
  msg_ok "Installed Happier relay host"

  if [[ "${REMOTE_ACCESS}" == "tailscale" ]]; then
    msg_info "Installing Tailscale"
    ID=$(grep "^ID=" /etc/os-release | cut -d"=" -f2)
    VER=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d"=" -f2)
    curl -fsSL "https://pkgs.tailscale.com/stable/${ID}/${VER}.noarmor.gpg" \
      | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/${ID} ${VER} main" \
      >/etc/apt/sources.list.d/tailscale.list
    $STD apt-get update -qq
    $STD apt-get install -y tailscale
    systemctl enable -q --now tailscaled
    msg_ok "Installed Tailscale"

    if command -v tailscale >/dev/null 2>&1; then
      tailscale set --operator=happier >/dev/null 2>&1 || true
    fi

    if [[ -n "${TAILSCALE_AUTHKEY}" ]]; then
      msg_info "Enrolling Tailscale (pre-auth key)"
      if command -v timeout >/dev/null 2>&1; then
        timeout 120 tailscale up --authkey="${TAILSCALE_AUTHKEY}" >/dev/null 2>&1 || true
      else
        tailscale up --authkey="${TAILSCALE_AUTHKEY}" >/dev/null 2>&1 || true
      fi
      tailscale set --operator=happier >/dev/null 2>&1 || true
      TAILSCALE_ENABLE_SERVE="1"
    fi

    if [[ "${TAILSCALE_ENABLE_SERVE}" == "1" ]]; then
      msg_info "Enabling Tailscale Serve (best-effort)"
      tailscale serve reset >/dev/null 2>&1 || true
      tailscale serve --bg "http://127.0.0.1:${HAPPIER_SERVER_PORT}" >/dev/null 2>&1 || true
      TAILSCALE_HTTPS_URL="$(resolve_tailscale_https_url_with_retries 40 3 || true)"
      if [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
        msg_ok "Tailscale Serve enabled"
        if [[ "${AUTOSTART}" == "1" ]]; then
          "${HAPPIER_CLI_BIN}" relay host restart --mode system --channel "${HAPPIER_CHANNEL}" >/dev/null 2>&1 || true
        fi
      else
        msg_ok "Tailscale Serve attempted (no HTTPS URL detected yet)"
      fi
    fi
  fi

  if [[ "${AUTOSTART}" != "1" ]]; then
    local relay_service=""
    relay_service="$(channel_relay_service_name "${HAPPIER_CHANNEL}")"
    msg_info "Disabling autostart (relay system service)"
    systemctl disable -q --now "${relay_service}" >/dev/null 2>&1 || true
    msg_ok "Autostart disabled"
  fi
}

configure_devbox_server_profile() {
  mkdir -p /home/happier/.happier
  chown -R happier:happier /home/happier/.happier

  local localApiUrl="http://127.0.0.1:${HAPPIER_SERVER_PORT}"
  local canonicalUrl=""
  if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
    canonicalUrl="${PUBLIC_URL}"
  elif [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
    canonicalUrl="${TAILSCALE_HTTPS_URL}"
  elif [[ "${REMOTE_ACCESS}" == "none" ]]; then
    canonicalUrl="http://${LOCAL_IP}:${HAPPIER_SERVER_PORT}"
  else
    canonicalUrl="${localApiUrl}"
  fi

  local webappUrl=""
  if [[ "${SERVE_UI}" == "1" ]]; then
    webappUrl="${canonicalUrl}"
  else
    webappUrl="$(channel_hosted_webapp_url "${HAPPIER_CHANNEL}")"
  fi

  msg_info "Configuring Happier server profile (devbox)"
  local server_add_args=(server add --name "proxmox" --server-url "${canonicalUrl}" --use)
  if [[ "${canonicalUrl}" == "${localApiUrl}" ]]; then
    :
  else
    server_add_args+=(--local-server-url "${localApiUrl}")
  fi
  [[ -n "${webappUrl}" ]] && server_add_args+=(--webapp-url "${webappUrl}")
  $STD sudo -u happier -H "${HAPPIER_CLI_BIN}" "${server_add_args[@]}" </dev/null
  msg_ok "Server profile saved"
}

install_devbox_background_service() {
  msg_info "Installing background service (devbox)"
  HOME="/home/happier" \
    HAPPIER_HOME_DIR="/home/happier/.happier" \
    $STD sudo -u happier -H "${HAPPIER_CLI_BIN}" --server proxmox service install --mode system --system-user happier --yes </dev/null
  msg_ok "Background service installed"
}

if [[ "${INSTALL_METHOD}" == "installers" ]]; then
  install_happier_cli_binary
  install_managed_relay_runtime

  if [[ "${INSTALL_TYPE}" == "devbox" ]]; then
    install_devbox_cli_compat_wrapper
    configure_devbox_server_profile

    if [[ "${AUTOSTART}" == "1" ]]; then
      install_devbox_background_service
    else
      msg_info "Autostart disabled: skipping background service install"
      msg_ok "Background service skipped"
    fi
  fi

  # Post-install output: configure server → sign in/create → connect daemon/terminal.
  msg_ok "Install complete"
  RELAY_SERVICE_NAME="$(channel_relay_service_name "${HAPPIER_CHANNEL}")"
  CLIENT_CLI_NAME="${HAPPIER_CLI_NAME}"
  HOSTED_WEBAPP_URL="$(channel_hosted_webapp_url "${HAPPIER_CHANNEL}")"
  if [[ "${SETUP_BIND}" == "loopback" ]]; then
    echo -e "${INFO}${YW} Access (HTTP, inside container): ${CL}${TAB}${GATEWAY}${BGN}http://127.0.0.1:${HAPPIER_SERVER_PORT}${CL}"
    echo -e "${INFO}${YW} Note:${CL} bind=loopback is not reachable from your LAN."
  else
    echo -e "${INFO}${YW} Access (HTTP): ${CL}${TAB}${GATEWAY}${BGN}http://${LOCAL_IP}:${HAPPIER_SERVER_PORT}${CL}"
  fi
  if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
    echo -e "${INFO}${YW} Access (HTTPS): ${CL}${TAB}${GATEWAY}${BGN}${PUBLIC_URL}${CL}"
  else
    echo -e "${INFO}${YW} IMPORTANT: ${CL}For remote web UI access you need HTTPS (Tailscale Serve or reverse proxy)."
  fi
  if [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
    echo -e "${INFO}${YW} Access (HTTPS): ${CL}${TAB}${GATEWAY}${BGN}${TAILSCALE_HTTPS_URL}${CL}"
  elif [[ "${REMOTE_ACCESS}" == "tailscale" ]]; then
    echo -e "${INFO}${YW} Tailscale:${CL} enroll it inside the container, then enable Serve:"
    echo -e "${TAB}${GATEWAY}${BGN}tailscale up${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}tailscale set --operator=happier${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}tailscale serve --bg http://127.0.0.1:${HAPPIER_SERVER_PORT}${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}tailscale serve status${CL}"
  fi

  if [[ "${AUTOSTART}" != "1" ]]; then
    echo -e "${INFO}${YW} Note:${CL} autostart is disabled, so services are not running."
    echo -e "${INFO}${YW} Start manually:${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}systemctl start ${RELAY_SERVICE_NAME}${CL}"
  fi

  echo -e "${INFO}${YW} Next steps:${CL}"

  urlencode_component() {
    python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
  }

  CLIENT_SERVER_URL=""
  if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
    CLIENT_SERVER_URL="${PUBLIC_URL}"
  elif [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
    CLIENT_SERVER_URL="${TAILSCALE_HTTPS_URL}"
  elif [[ "${REMOTE_ACCESS}" == "tailscale" ]]; then
    CLIENT_SERVER_URL="<your-tailscale-https-url>"
  elif [[ "${SETUP_BIND}" == "loopback" ]]; then
    CLIENT_SERVER_URL="http://127.0.0.1:${HAPPIER_SERVER_PORT}"
  else
    CLIENT_SERVER_URL="http://${LOCAL_IP}:${HAPPIER_SERVER_PORT}"
  fi

  CLIENT_WEBAPP_URL=""
  if [[ "${SERVE_UI}" == "1" ]]; then
    if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
      CLIENT_WEBAPP_URL="${PUBLIC_URL}"
    elif [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
      CLIENT_WEBAPP_URL="${TAILSCALE_HTTPS_URL}"
    elif [[ "${REMOTE_ACCESS}" == "tailscale" ]]; then
      CLIENT_WEBAPP_URL=""
    elif [[ "${SETUP_BIND}" == "loopback" ]]; then
      CLIENT_WEBAPP_URL="http://127.0.0.1:${HAPPIER_SERVER_PORT}"
    else
      CLIENT_WEBAPP_URL="http://${LOCAL_IP}:${HAPPIER_SERVER_PORT}"
    fi
  else
    CLIENT_WEBAPP_URL="${HOSTED_WEBAPP_URL}"
  fi

  echo -e "${TAB}${YW}1)${CL} Configure your app to use this server:"
  echo -e "${TAB}${TAB}${YW}Configure links:${CL}"
  if [[ "${CLIENT_SERVER_URL}" == "<"*">" ]]; then
    echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}happier://server?url=${CLIENT_SERVER_URL}${CL}"
    if [[ -n "${CLIENT_WEBAPP_URL}" ]]; then
      echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${CLIENT_WEBAPP_URL}/server?url=${CLIENT_SERVER_URL}&auto=1${CL}"
    fi
  else
    CLIENT_SERVER_URL_ENC="$(urlencode_component "${CLIENT_SERVER_URL}")"
    echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}happier://server?url=${CLIENT_SERVER_URL_ENC}${CL}"
    if [[ -n "${HOSTED_WEBAPP_URL}" && "${CLIENT_WEBAPP_URL}" == "${HOSTED_WEBAPP_URL}" && "${CLIENT_SERVER_URL}" != https://* ]]; then
      echo -e "${TAB}${TAB}${TAB}${YW}Web app note:${CL} requires an HTTPS server URL (use Tailscale Serve or reverse proxy)."
    elif [[ -z "${CLIENT_WEBAPP_URL}" && "${HAPPIER_CHANNEL}" == "dev" ]]; then
      echo -e "${TAB}${TAB}${TAB}${YW}Dev lane note:${CL} there is no hosted web UI for the dev channel unless you serve the UI locally."
    elif [[ -n "${CLIENT_WEBAPP_URL}" ]]; then
      echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${CLIENT_WEBAPP_URL}/server?url=${CLIENT_SERVER_URL_ENC}&auto=1${CL}"
    fi
  fi

  echo -e "${TAB}${YW}2)${CL} Sign in or create an account (recommended: mobile app)."

  if [[ "${INSTALL_TYPE}" == "devbox" ]]; then
    echo -e "${TAB}${YW}3)${CL} Authenticate the daemon running in this container:"
    if [[ "${REMOTE_ACCESS}" == "tailscale" && -z "${TAILSCALE_HTTPS_URL}" ]]; then
      echo -e "${TAB}${TAB}${YW}Note:${CL} you selected Tailscale but no HTTPS URL was detected yet."
      echo -e "${TAB}${TAB}${YW}First:${CL} enroll Tailscale and enable Serve (see commands above), then set the canonical URL:"
      if [[ "${SERVE_UI}" == "1" ]]; then
        echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}sudo -u happier -H ${CLIENT_CLI_NAME} server set --server-url <your-tailscale-https-url> --local-server-url http://127.0.0.1:${HAPPIER_SERVER_PORT} --webapp-url <your-tailscale-https-url>${CL}"
      else
        echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}sudo -u happier -H ${CLIENT_CLI_NAME} server set --server-url <your-tailscale-https-url> --local-server-url http://127.0.0.1:${HAPPIER_SERVER_PORT}${CL}"
      fi
    fi
    echo -e "${TAB}${TAB}${GATEWAY}${BGN}sudo -u happier -H ${CLIENT_CLI_NAME} auth login${CL}"
    if [[ "${AUTOSTART}" != "1" ]]; then
      echo -e "${TAB}${TAB}${YW}If you disabled autostart:${CL} start the daemon manually:"
      echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}sudo -u happier -H ${CLIENT_CLI_NAME} daemon start${CL}"
    fi
  else
    echo -e "${TAB}${YW}3)${CL} To connect a terminal/daemon from your laptop/desktop:"
    echo -e "${TAB}${TAB}${YW}a)${CL} Add/select this server in your CLI:"
    if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
      echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${CLIENT_CLI_NAME} server add --server-url ${PUBLIC_URL} --use${CL}"
    elif [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
      echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${CLIENT_CLI_NAME} server add --server-url ${TAILSCALE_HTTPS_URL} --use${CL}"
    elif [[ "${REMOTE_ACCESS}" == "tailscale" ]]; then
      echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${CLIENT_CLI_NAME} server add --server-url <your-tailscale-https-url> --use${CL}"
    elif [[ "${SETUP_BIND}" == "loopback" ]]; then
      echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${CLIENT_CLI_NAME} server add --server-url http://127.0.0.1:${HAPPIER_SERVER_PORT} --use${CL}"
    else
      echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${CLIENT_CLI_NAME} server add --server-url http://${LOCAL_IP}:${HAPPIER_SERVER_PORT} --use${CL}"
    fi
    echo -e "${TAB}${TAB}${YW}b)${CL} Then run:"
    echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${CLIENT_CLI_NAME} auth login${CL}"
  fi

  motd_ssh
  customize

  # customize() creates /usr/bin/update pointing to community-scripts; fix to use the fork.
  cat >/usr/bin/update <<'UPDATEEOF'
#!/usr/bin/env bash
set -euo pipefail
curl -fsSL https://raw.githubusercontent.com/happier-dev/ProxmoxVE/main/ct/happier.sh | bash
UPDATEEOF
  chmod +x /usr/bin/update

  cleanup_lxc
  exit 0
fi

SETUP_ENV=()
SETUP_ENV+=("HAPPIER_SERVER_HOST=${SERVER_HOST}")
SETUP_ENV+=("HAPPIER_STACK_BIND_MODE=${SETUP_BIND}")
# redis-memory-server postinstall can fail in unprivileged LXC; not required for production runtime.
SETUP_ENV+=("REDISMS_DISABLE_POSTINSTALL=true")
if [[ "${INSTALL_TYPE}" == "server_only" ]]; then
  SETUP_ENV+=("HAPPIER_STACK_DAEMON=0")
fi
if [[ "${SERVE_UI}" != "1" ]]; then
  SETUP_ENV+=("HAPPIER_STACK_SERVE_UI=0")
fi

SETUP_ARGS=()
SETUP_ARGS+=("--profile=selfhost")
SETUP_ARGS+=("--server-flavor=light")
SETUP_ARGS+=("--non-interactive")
SETUP_ARGS+=("--no-auth")
SETUP_ARGS+=("--no-autostart")
SETUP_ARGS+=("--no-start-now")
SETUP_ARGS+=("--bind=${SETUP_BIND}")
if [[ "${SERVE_UI}" != "1" ]]; then
  SETUP_ARGS+=("--no-ui-deps" "--no-ui-build")
fi
if [[ "${HAPPIER_CHANNEL}" == "preview" ]]; then
  SETUP_ARGS+=("--stable-branch=preview")
fi

msg_info "Installing Happier (hstack setup-from-source) — package: ${STACK_PACKAGE}"
(
  # Avoid sudo inheriting an inaccessible cwd (e.g. /root) for the happier user.
  cd /home/happier || { msg_error "Failed to access /home/happier"; exit 1; }
  $STD sudo -u happier -H env "${SETUP_ENV[@]}" \
    npx --yes -p "${STACK_PACKAGE}" hstack setup-from-source "${SETUP_ARGS[@]}" </dev/null
)
msg_ok "Installed Happier (hstack setup-from-source)"

# Resolve actual hstack binary and paths. Some setups may not use the default stack/workdir.
HSTACK_BIN="/home/happier/.happier-stack/bin/hstack"
if [[ ! -x "$HSTACK_BIN" ]]; then
  HSTACK_BIN="$(sudo -u happier -H bash -lc 'command -v hstack || true' | tr -d '\r')"
fi
if [[ -z "$HSTACK_BIN" || ! -x "$HSTACK_BIN" ]]; then
  msg_error "hstack binary not found after setup."
  exit 1
fi

HSTACK_HOME_DIR="/home/happier/.happier-stack"
STACK_NAME="main"
STACK_LABEL="dev.happier.stack"
STACK_ENV_FILE="/home/happier/.happier/stacks/${STACK_NAME}/env"
HSTACK_WHERE_JSON="$(sudo -u happier -H "$HSTACK_BIN" where --json 2>/dev/null || true)"
if [[ -n "$HSTACK_WHERE_JSON" ]] && command -v jq >/dev/null 2>&1; then
  _home_dir="$(printf '%s' "$HSTACK_WHERE_JSON" | jq -r '.homeDir // empty' 2>/dev/null || true)"
  _stack_name="$(printf '%s' "$HSTACK_WHERE_JSON" | jq -r '.stack.name // empty' 2>/dev/null || true)"
  _stack_label="$(printf '%s' "$HSTACK_WHERE_JSON" | jq -r '.stack.label // empty' 2>/dev/null || true)"
  _stack_env="$(printf '%s' "$HSTACK_WHERE_JSON" | jq -r '.envFiles.main.path // empty' 2>/dev/null || true)"
  [[ -n "$_home_dir" ]] && HSTACK_HOME_DIR="$_home_dir"
  [[ -n "$_stack_name" ]] && STACK_NAME="$_stack_name"
  [[ -n "$_stack_label" ]] && STACK_LABEL="$_stack_label"
  [[ -n "$_stack_env" ]] && STACK_ENV_FILE="$_stack_env"
fi
if [[ ! -f "$STACK_ENV_FILE" ]]; then
  _fallback_env="$(find /home/happier/.happier/stacks -mindepth 2 -maxdepth 2 -type f -name env 2>/dev/null | head -n 1 || true)"
  [[ -n "$_fallback_env" ]] && STACK_ENV_FILE="$_fallback_env"
fi
HAPPIER_HOME="$(getent passwd happier | cut -d: -f6 | tr -d '\r' || true)"
[[ -z "$HAPPIER_HOME" ]] && HAPPIER_HOME="/home/happier"
mkdir -p "$(dirname "$STACK_ENV_FILE")"
touch "$STACK_ENV_FILE"
chown happier:happier "$STACK_ENV_FILE"

set_env_kv() {
  local file="$1" key="$2" value="$3"
  local escaped
  escaped="$(printf '%s' "$value" | sed -e 's/[|&]/\\\\&/g')"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

remove_env_kv() {
  local file="$1" key="$2"
  [[ -f "${file}" ]] || return 0
  sed -i "/^${key}=/d" "${file}"
}

tailscale_wait_until_online() {
  local attempts="${1:-20}"
  local sleep_s="${2:-2}"
  local i=1
  while (( i <= attempts )); do
    if "$TAILSCALE_BIN" ip -4 >/dev/null 2>&1 || "$TAILSCALE_BIN" ip -6 >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_s"
    i=$((i + 1))
  done
  return 1
}

tailscale_status_json_field() {
  local key="$1"
  "$TAILSCALE_BIN" status --json 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('${key}',''))" 2>/dev/null || true
}

wait_for_systemd_active() {
  local unit="$1"
  local attempts="${2:-30}"
  local sleep_s="${3:-1}"
  local i=1
  while (( i <= attempts )); do
    if systemctl is-active --quiet "$unit" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_s"
    i=$((i + 1))
  done
  return 1
}

set_env_kv "$STACK_ENV_FILE" "HAPPIER_SERVER_HOST" "${SERVER_HOST}"
set_env_kv "$STACK_ENV_FILE" "HAPPIER_STACK_BIND_MODE" "${SETUP_BIND}"
if [[ "${INSTALL_TYPE}" == "server_only" ]]; then
  set_env_kv "$STACK_ENV_FILE" "HAPPIER_STACK_DAEMON" "0"
fi
if [[ "${SERVE_UI}" != "1" ]]; then
  set_env_kv "$STACK_ENV_FILE" "HAPPIER_STACK_SERVE_UI" "0"
fi
if [[ "${INSTALL_TYPE}" == "devbox" ]]; then
  set_env_kv "$STACK_ENV_FILE" "HAPPIER_STACK_DAEMON_WAIT_FOR_AUTH" "1"
fi

# Set a best-effort server URL early so autostart/manual start uses it on first boot.
get_lxc_ip
if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
  set_env_kv "$STACK_ENV_FILE" "HAPPIER_STACK_SERVER_URL" "${PUBLIC_URL}"
  set_env_kv "$STACK_ENV_FILE" "HAPPIER_PUBLIC_SERVER_URL" "${PUBLIC_URL}"
elif [[ "${REMOTE_ACCESS}" != "tailscale" ]]; then
  set_env_kv "$STACK_ENV_FILE" "HAPPIER_STACK_SERVER_URL" "http://${LOCAL_IP}:${HAPPIER_SERVER_PORT}"
  set_env_kv "$STACK_ENV_FILE" "HAPPIER_PUBLIC_SERVER_URL" "http://${LOCAL_IP}:${HAPPIER_SERVER_PORT}"
fi
if [[ "${SERVE_UI}" == "1" && "${REMOTE_ACCESS}" == "proxy" ]]; then
  # Advertise that terminal-connect web UI is served from this same origin.
  set_env_kv "$STACK_ENV_FILE" "HAPPIER_WEBAPP_URL" "${PUBLIC_URL}"
elif [[ "${SERVE_UI}" == "1" && "${REMOTE_ACCESS}" != "tailscale" && "${SETUP_BIND}" == "lan" ]]; then
  # Local-only installs can still serve the UI (but will not be reachable off-LAN without HTTPS).
  set_env_kv "$STACK_ENV_FILE" "HAPPIER_WEBAPP_URL" "http://${LOCAL_IP}:${HAPPIER_SERVER_PORT}"
elif [[ "${SERVE_UI}" != "1" ]]; then
  # Prefer the hosted web app when the local UI is not served.
  FROM_SOURCE_HOSTED_WEBAPP_URL="$(channel_hosted_webapp_url "${HAPPIER_CHANNEL}")"
  if [[ -n "${FROM_SOURCE_HOSTED_WEBAPP_URL}" ]]; then
    set_env_kv "$STACK_ENV_FILE" "HAPPIER_WEBAPP_URL" "${FROM_SOURCE_HOSTED_WEBAPP_URL}"
  else
    remove_env_kv "$STACK_ENV_FILE" "HAPPIER_WEBAPP_URL"
  fi
fi

if [[ "${SERVE_UI}" == "1" ]]; then
  msg_info "Building Happier web UI (required to serve UI)"
  $STD sudo -u happier -H "$HSTACK_BIN" build --no-tauri </dev/null
  msg_ok "Built Happier web UI"
fi

if [[ "${AUTOSTART}" != "1" ]]; then
  msg_info "Starting Happier"
  mkdir -p /home/happier/.happier/logs
  chown -R happier:happier /home/happier/.happier/logs
  sudo -u happier -H bash -lc "
    HAPPIER_NO_BROWSER_OPEN=1 nohup \"$HSTACK_BIN\" start --restart </dev/null >/home/happier/.happier/logs/hstack-start.out.log 2>&1 &
  "
  msg_ok "Started Happier"
fi

if [[ "${REMOTE_ACCESS}" == "tailscale" ]]; then
  msg_info "Installing Tailscale"
  ID=$(grep "^ID=" /etc/os-release | cut -d"=" -f2)
  VER=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d"=" -f2)
  curl -fsSL "https://pkgs.tailscale.com/stable/${ID}/${VER}.noarmor.gpg" \
    | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/${ID} ${VER} main" \
    >/etc/apt/sources.list.d/tailscale.list
  $STD apt-get update -qq
  $STD apt-get install -y tailscale
  systemctl enable -q --now tailscaled
  msg_ok "Installed Tailscale"

  # Pin the binary path to avoid shell/MOTD output polluting command-path resolution.
  TAILSCALE_BIN="$(command -v tailscale 2>/dev/null || true)"
  [[ -z "$TAILSCALE_BIN" ]] && TAILSCALE_BIN="/usr/bin/tailscale"
  set_env_kv "$STACK_ENV_FILE" "HAPPIER_STACK_TAILSCALE_BIN" "$TAILSCALE_BIN"
  set_env_kv "$STACK_ENV_FILE" "HAPPIER_STACK_TAILSCALE_SERVE" "1"
  # hstack runs as the happier user; make it an approved tailscale operator.
  "$TAILSCALE_BIN" set --operator=happier >/dev/null 2>&1 || msg_warn "Could not set tailscale operator to happier (continuing)."

  if [[ -n "${TAILSCALE_AUTHKEY}" ]]; then
    msg_info "Enrolling Tailscale (pre-auth key)"
    if ! wait_for_systemd_active tailscaled 30 1; then
      msg_warn "tailscaled service did not report active yet; continuing anyway."
    fi
    TAILSCALE_UP_OUTPUT=""
    TAILSCALE_UP_EXIT=0
    TAILSCALE_UP_ARGS=(up "--authkey=${TAILSCALE_AUTHKEY}")
    if command -v timeout >/dev/null 2>&1; then
      if TAILSCALE_UP_OUTPUT="$(timeout 120 "$TAILSCALE_BIN" "${TAILSCALE_UP_ARGS[@]}" 2>&1)"; then
        TAILSCALE_UP_EXIT=0
      else
        TAILSCALE_UP_EXIT=$?
      fi
      if [[ $TAILSCALE_UP_EXIT -eq 124 || $TAILSCALE_UP_EXIT -eq 137 ]]; then
        msg_warn "tailscale up timed out. Continuing with manual enrollment instructions."
      fi
    else
      if TAILSCALE_UP_OUTPUT="$("$TAILSCALE_BIN" "${TAILSCALE_UP_ARGS[@]}" 2>&1)"; then
        TAILSCALE_UP_EXIT=0
      else
        TAILSCALE_UP_EXIT=$?
      fi
    fi
    "$TAILSCALE_BIN" set --operator=happier >/dev/null 2>&1 || true
    if printf '%s' "${TAILSCALE_UP_OUTPUT}" | grep -Eiq 'invalid key|not valid|expired|unauthorized'; then
      TAILSCALE_AUTH_INVALID="1"
      TAILSCALE_NEEDS_LOGIN="1"
      TAILSCALE_AUTH_URL="$(tailscale_status_json_field AuthURL)"
      msg_warn "Tailscale auth key was rejected."
      msg_warn "tailscale up output: $(printf '%s' "${TAILSCALE_UP_OUTPUT}" | tail -n 1)"
      msg_warn "Use a fresh reusable pre-auth key, or run tailscale up manually after install."
    elif [[ $TAILSCALE_UP_EXIT -eq 124 || $TAILSCALE_UP_EXIT -eq 137 ]]; then
      TAILSCALE_NEEDS_LOGIN="1"
      TAILSCALE_AUTH_URL="$(tailscale_status_json_field AuthURL)"
      msg_warn "Tailscale enrollment did not complete within the timeout window."
      if [[ -n "${TAILSCALE_AUTH_URL}" ]]; then
        msg_warn "Tailscale login URL: ${TAILSCALE_AUTH_URL}"
      else
        msg_warn "Run inside the container: tailscale up"
      fi
    elif tailscale_wait_until_online 90 2; then
      msg_ok "Tailscale enrollment attempted"
      TAILSCALE_ENABLE_SERVE="1"
    else
      TAILSCALE_STATE="$(tailscale_status_json_field BackendState)"
      TAILSCALE_AUTH_URL="$(tailscale_status_json_field AuthURL)"
      msg_warn "Tailscale enrollment attempted, but node is not online yet (state: ${TAILSCALE_STATE:-unknown})."
      if [[ -n "${TAILSCALE_AUTH_URL}" ]]; then
        TAILSCALE_NEEDS_LOGIN="1"
        msg_warn "Tailscale still needs login. Auth URL: ${TAILSCALE_AUTH_URL}"
        msg_warn "Your pre-auth key may be expired, one-time and already used, or not reusable."
      else
        msg_warn "Check Tailscale networking prerequisites (outbound access and /dev/net/tun availability)."
      fi
      if [[ -n "${TAILSCALE_UP_OUTPUT}" ]]; then
        msg_warn "tailscale up output: $(printf '%s' "${TAILSCALE_UP_OUTPUT}" | tail -n 1)"
      fi
    fi
  fi
fi

if [[ "${AUTOSTART}" == "1" ]]; then
  # Ensure the logs directory exists before the systemd service starts,
  # otherwise StandardOutput=append:... fails with status=209/STDOUT.
  mkdir -p "$(dirname "$STACK_ENV_FILE")/logs"
  chown -R happier:happier "$(dirname "$STACK_ENV_FILE")/logs"
  msg_info "Enabling autostart (systemd system service)"
  $STD env HOME="${HAPPIER_HOME}" \
  HAPPIER_STACK_HOME_DIR="${HSTACK_HOME_DIR}" \
  HAPPIER_STACK_ENV_FILE="${STACK_ENV_FILE}" \
  "$HSTACK_BIN" service install --mode=system --system-user=happier

  # hstack currently writes WorkingDirectory=%h for system services.
  # For system units this can resolve to /root; force the explicit happier home.
  SYSTEMD_UNIT_PATH="/etc/systemd/system/${STACK_LABEL}.service"
  if [[ -f "$SYSTEMD_UNIT_PATH" ]]; then
    sed -i "s|^WorkingDirectory=.*|WorkingDirectory=${HAPPIER_HOME}|" "$SYSTEMD_UNIT_PATH"
    if ! grep -q '^User=happier$' "$SYSTEMD_UNIT_PATH"; then
      sed -i '/^\[Service\]/a User=happier' "$SYSTEMD_UNIT_PATH"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart "${STACK_LABEL}.service" >/dev/null 2>&1 || true
  fi
  msg_ok "Autostart enabled"
fi

if [[ "${REMOTE_ACCESS}" == "tailscale" && "${TAILSCALE_ENABLE_SERVE}" == "1" ]]; then
  msg_info "Enabling Tailscale Serve (best-effort)"
  sudo -u happier -H "$HSTACK_BIN" tailscale enable >/dev/null 2>&1 || true

  # On fresh nodes, cert/DNS readiness can lag behind tailscale up by ~1-2 minutes.
  # Keep retrying serve mapping before giving up to avoid manual follow-up in most installs.
  msg_info "Waiting for Tailscale HTTPS URL (this can take a minute or two on fresh nodes)"
  if tailscale_wait_until_online 90 2; then
    "$TAILSCALE_BIN" serve reset >/dev/null 2>&1 || true
    for _ in $(seq 1 45); do
      "$TAILSCALE_BIN" serve --bg "http://127.0.0.1:${HAPPIER_SERVER_PORT}" >/dev/null 2>&1 || true
      TAILSCALE_HTTPS_URL="$(resolve_tailscale_https_url_with_retries 2 1 || true)"
      if [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
        break
      fi
      sleep 3
    done
  else
    TAILSCALE_STATE="$(tailscale_status_json_field BackendState)"
    TAILSCALE_AUTH_URL="$(tailscale_status_json_field AuthURL)"
    msg_warn "Tailscale is not online yet; skipping automatic Serve URL detection (state: ${TAILSCALE_STATE:-unknown})."
    if [[ -n "${TAILSCALE_AUTH_URL}" ]]; then
      TAILSCALE_NEEDS_LOGIN="1"
      msg_warn "Tailscale still needs login. Auth URL: ${TAILSCALE_AUTH_URL}"
    fi
  fi

  if [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
    set_env_kv "$STACK_ENV_FILE" "HAPPIER_STACK_SERVER_URL" "${TAILSCALE_HTTPS_URL}"
    set_env_kv "$STACK_ENV_FILE" "HAPPIER_PUBLIC_SERVER_URL" "${TAILSCALE_HTTPS_URL}"
    if [[ "${SERVE_UI}" == "1" ]]; then
      set_env_kv "$STACK_ENV_FILE" "HAPPIER_WEBAPP_URL" "${TAILSCALE_HTTPS_URL}"
    fi
    # The service was started earlier without the Tailscale URL; restart so
    # it picks up the correct HAPPIER_STACK_SERVER_URL for deep links/QR codes.
    if [[ "${AUTOSTART}" == "1" ]]; then
      systemctl restart "${STACK_LABEL}.service" >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
    msg_ok "Tailscale Serve enabled"
  else
    msg_ok "Tailscale Serve attempted (no HTTPS URL detected yet)"
  fi
elif [[ "${REMOTE_ACCESS}" == "tailscale" ]]; then
  if [[ "${TAILSCALE_AUTH_INVALID}" == "1" ]]; then
    msg_warn "Skipping Tailscale Serve setup: auth key was invalid."
  elif [[ "${TAILSCALE_NEEDS_LOGIN}" == "1" ]]; then
    msg_warn "Skipping Tailscale Serve setup: tailscale login is still required."
  else
    msg_warn "Skipping Tailscale Serve setup: tailscale is not online."
  fi
fi

msg_ok "Install complete"

if [[ "${SETUP_BIND}" == "loopback" ]]; then
  echo -e "${INFO}${YW} Access (HTTP, inside container): ${CL}${TAB}${GATEWAY}${BGN}http://127.0.0.1:${HAPPIER_SERVER_PORT}${CL}"
  echo -e "${INFO}${YW} Note:${CL} bind=loopback is not reachable from your LAN."
else
  echo -e "${INFO}${YW} Access (HTTP): ${CL}${TAB}${GATEWAY}${BGN}http://${LOCAL_IP}:${HAPPIER_SERVER_PORT}${CL}"
fi

if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
  echo -e "${INFO}${YW} Access (HTTPS): ${CL}${TAB}${GATEWAY}${BGN}${PUBLIC_URL}${CL}"
else
  echo -e "${INFO}${YW} IMPORTANT: ${CL}For remote web UI access you need HTTPS (Tailscale Serve or reverse proxy)."
fi
if [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
  echo -e "${INFO}${YW} Access (HTTPS): ${CL}${TAB}${GATEWAY}${BGN}${TAILSCALE_HTTPS_URL}${CL}"
elif [[ "${REMOTE_ACCESS}" == "tailscale" ]]; then
  [[ -z "${TAILSCALE_AUTH_URL}" ]] && TAILSCALE_AUTH_URL="$(tailscale_status_json_field AuthURL)"
  if [[ "${TAILSCALE_AUTH_INVALID}" == "1" ]]; then
    echo -e "${INFO}${YW} Tailscale auth failed:${CL} provided pre-auth key was rejected."
    echo -e "${TAB}${YW}Fix:${CL} provide a valid reusable auth key, or run manual login:"
    if [[ -n "${TAILSCALE_AUTH_URL}" ]]; then
      echo -e "${TAB}${YW}Login URL:${CL} ${TAILSCALE_AUTH_URL}"
    fi
    echo -e "${TAB}${GATEWAY}${BGN}tailscale up${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}tailscale set --operator=happier${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}tailscale serve --bg http://127.0.0.1:${HAPPIER_SERVER_PORT}${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}su - happier -c \"${HSTACK_BIN} tailscale url\"${CL}"
  elif [[ -z "${TAILSCALE_AUTHKEY}" || "${TAILSCALE_NEEDS_LOGIN}" == "1" ]]; then
    echo -e "${INFO}${YW} Tailscale:${CL} enroll it inside the container, then enable Serve:"
    if [[ -n "${TAILSCALE_AUTH_URL}" ]]; then
      echo -e "${TAB}${YW}Login URL:${CL} ${TAILSCALE_AUTH_URL}"
    fi
    echo -e "${TAB}${GATEWAY}${BGN}tailscale up${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}tailscale set --operator=happier${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}su - happier -c \"${HSTACK_BIN} tailscale enable\"${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}su - happier -c \"${HSTACK_BIN} tailscale url\"${CL}"
  elif [[ "${TAILSCALE_ENABLE_SERVE}" == "1" ]]; then
    echo -e "${INFO}${YW} Tailscale Serve:${CL} was attempted but no HTTPS URL was detected yet."
    echo -e "${TAB}${YW}Try again in a minute:${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}su - happier -c \"${HSTACK_BIN} tailscale url\"${CL}"
    echo -e "${TAB}${YW}If still missing, reset/recreate Serve mapping:${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}tailscale serve reset${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}tailscale serve --bg http://127.0.0.1:${HAPPIER_SERVER_PORT}${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}tailscale serve status${CL}"
  fi
fi
echo -e "${INFO}${YW} Next steps:${CL}"
echo -e "${TAB}${YW}1)${CL} Connect with the mobile app (recommended): scan the QR code shown by 'auth login'."
echo -e "${TAB}${TAB}${YW}Tip:${CL} scanning the QR automatically selects the correct server in the app."
echo -e "${TAB}${TAB}${YW}Fallback:${CL} you can also configure the server manually using the links below."

urlencode_component() {
  python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

CLIENT_SERVER_URL=""
if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
  CLIENT_SERVER_URL="${PUBLIC_URL}"
elif [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
  CLIENT_SERVER_URL="${TAILSCALE_HTTPS_URL}"
elif [[ "${REMOTE_ACCESS}" == "tailscale" ]]; then
  CLIENT_SERVER_URL="<your-tailscale-https-url>"
elif [[ "${SETUP_BIND}" == "loopback" ]]; then
  CLIENT_SERVER_URL="http://127.0.0.1:${HAPPIER_SERVER_PORT}"
else
  CLIENT_SERVER_URL="http://${LOCAL_IP}:${HAPPIER_SERVER_PORT}"
fi

CLIENT_WEBAPP_URL=""
if [[ "${SERVE_UI}" == "1" ]]; then
  if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
    CLIENT_WEBAPP_URL="${PUBLIC_URL}"
  elif [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
    CLIENT_WEBAPP_URL="${TAILSCALE_HTTPS_URL}"
  elif [[ "${REMOTE_ACCESS}" == "tailscale" ]]; then
    CLIENT_WEBAPP_URL=""
  elif [[ "${SETUP_BIND}" == "loopback" ]]; then
    CLIENT_WEBAPP_URL="http://127.0.0.1:${HAPPIER_SERVER_PORT}"
  else
    CLIENT_WEBAPP_URL="http://${LOCAL_IP}:${HAPPIER_SERVER_PORT}"
  fi
else
  CLIENT_WEBAPP_URL="$(channel_hosted_webapp_url "${HAPPIER_CHANNEL}")"
fi

echo -e "${TAB}${TAB}${YW}Configure links:${CL}"
if [[ "${CLIENT_SERVER_URL}" == "<"*">" ]]; then
  echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}happier://server?url=${CLIENT_SERVER_URL}${CL}"
  if [[ -n "${CLIENT_WEBAPP_URL}" ]]; then
    echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${CLIENT_WEBAPP_URL}/server?url=${CLIENT_SERVER_URL}&auto=1${CL}"
  fi
else
  CLIENT_SERVER_URL_ENC="$(urlencode_component "${CLIENT_SERVER_URL}")"
  echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}happier://server?url=${CLIENT_SERVER_URL_ENC}${CL}"
  if [[ -n "${CLIENT_WEBAPP_URL}" && "${CLIENT_WEBAPP_URL}" == "$(channel_hosted_webapp_url "${HAPPIER_CHANNEL}")" && "${CLIENT_SERVER_URL}" != https://* ]]; then
    echo -e "${TAB}${TAB}${TAB}${YW}Web app note:${CL} requires an HTTPS server URL (use Tailscale Serve or reverse proxy)."
  elif [[ -z "${CLIENT_WEBAPP_URL}" && "${HAPPIER_CHANNEL}" == "dev" ]]; then
    echo -e "${TAB}${TAB}${TAB}${YW}Dev lane note:${CL} there is no hosted web UI for the dev channel unless you serve the UI locally."
  elif [[ -n "${CLIENT_WEBAPP_URL}" ]]; then
    echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${CLIENT_WEBAPP_URL}/server?url=${CLIENT_SERVER_URL_ENC}&auto=1${CL}"
  fi
fi

if [[ "${REMOTE_ACCESS}" == "tailscale" && -z "${TAILSCALE_HTTPS_URL}" ]]; then
  echo -e "${TAB}${TAB}${YW}After you have your Tailscale HTTPS URL:${CL} re-run these to get the correct links/QR codes:"
  echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}su - happier -c \"${HSTACK_BIN} tailscale url\"${CL}"
  echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}su - happier -c \"${HSTACK_BIN} auth login --method=mobile --no-open\"${CL}"
fi

if [[ "${INSTALL_TYPE}" == "devbox" ]]; then
  echo -e "${TAB}${YW}2)${CL} Connect the daemon running in this devbox (run inside the container):"
  echo -e "${TAB}${TAB}${GATEWAY}${BGN}sudo -u happier -H ${HSTACK_BIN} auth login --method=mobile --no-open${CL}"
  echo -e "${TAB}${YW}3)${CL} After login, restart the stack to start the daemon:"
  if [[ "${AUTOSTART}" == "1" ]]; then
    echo -e "${TAB}${TAB}${GATEWAY}${BGN}sudo -u happier -H ${HSTACK_BIN} service restart --mode=system${CL}"
  else
    echo -e "${TAB}${TAB}${GATEWAY}${BGN}sudo -u happier -H ${HSTACK_BIN} start --restart${CL}"
  fi
else
  echo -e "${TAB}${YW}2)${CL} To connect a terminal/daemon from your laptop/desktop:"
  echo -e "${TAB}${TAB}${YW}a)${CL} Add/select this server in your CLI:"
  CLIENT_CLI_NAME="$(channel_cli_name "${HAPPIER_CHANNEL}")"
  if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
    echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${CLIENT_CLI_NAME} server add --server-url ${PUBLIC_URL} --use${CL}"
  elif [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
    echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${CLIENT_CLI_NAME} server add --server-url ${TAILSCALE_HTTPS_URL} --use${CL}"
  elif [[ "${REMOTE_ACCESS}" == "tailscale" ]]; then
    echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${CLIENT_CLI_NAME} server add --server-url <your-tailscale-https-url> --use${CL}"
  else
    echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${CLIENT_CLI_NAME} server add --server-url http://${LOCAL_IP}:${HAPPIER_SERVER_PORT} --use${CL}"
  fi
  echo -e "${TAB}${TAB}${YW}b)${CL} Then run:"
  echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${CLIENT_CLI_NAME} auth login${CL}"
fi

motd_ssh
customize

# customize() creates /usr/bin/update pointing to community-scripts; fix to use the fork.
cat >/usr/bin/update <<'UPDATEEOF'
#!/usr/bin/env bash
set -euo pipefail
curl -fsSL https://raw.githubusercontent.com/happier-dev/ProxmoxVE/main/ct/happier.sh | bash
UPDATEEOF
chmod +x /usr/bin/update

cleanup_lxc
