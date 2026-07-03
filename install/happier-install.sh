#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: happier-dev
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://happier.dev

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"

# Shared Happier helpers (channel/UI-bundle/CLI resolvers + pinned minisign key).
# Fetched and sourced AFTER FUNCTIONS_FILE_PATH so the framework msg_* helpers
# are available. INSTALLER_REPO/INSTALLER_REF are inherited from build.func via
# lxc-attach (the shared file also defaults them when sourced standalone).
HAPPIER_COMMON_FUNC_URL="https://raw.githubusercontent.com/${INSTALLER_REPO}/${INSTALLER_REF}/misc/happier-common.func"
HAPPIER_COMMON_FUNC="$(curl -fsSL "${HAPPIER_COMMON_FUNC_URL}")" || {
  msg_error "Failed to download happier-common.func from: ${HAPPIER_COMMON_FUNC_URL}"
  exit 1
}
if [[ -z "${HAPPIER_COMMON_FUNC//[[:space:]]/}" ]]; then
  msg_error "Downloaded happier-common.func is empty: ${HAPPIER_COMMON_FUNC_URL}"
  exit 1
fi
source /dev/stdin <<<"${HAPPIER_COMMON_FUNC}"

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
DAEMON_AUTH="${HAPPIER_PVE_DAEMON_AUTH:-0}"            # 1 | 0 (interactive QR auth during install)
DAEMON_AUTH_DONE="0"
HAPPIER_CHANNEL_RAW="${HAPPIER_PVE_CHANNEL:-${HAPPIER_PVE_HSTACK_CHANNEL:-stable}}" # stable | preview | dev
STACK_PACKAGE_RAW="${HAPPIER_PVE_STACK_PACKAGE:-${HAPPIER_PVE_HSTACK_PACKAGE:-}}"    # e.g. @happier-dev/stack@latest
SERVER_PORT_RAW="${HAPPIER_PVE_SERVER_PORT:-}"                                       # optional explicit PORT override
INSTALL_AGENTS="${HAPPIER_PVE_INSTALL_AGENTS:-1}"      # 1 | 0 (install claude+codex on devbox)
DAEMON_GITHUB_PAT="${HAPPIER_PVE_GITHUB_PAT:-}"        # optional daemon GITHUB_PERSONAL_ACCESS_TOKEN
AUTO_UPDATE="${HAPPIER_PVE_AUTO_UPDATE:-0}"            # 1 | 0 (enable managed auto-update timer)
AUTO_UPDATE_AT="${HAPPIER_PVE_AUTO_UPDATE_AT:-04:00}"  # HH:MM for the auto-update timer
if [[ "${AUTO_UPDATE}" == "1" && ! "${AUTO_UPDATE_AT}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
  msg_warn "Invalid HAPPIER_PVE_AUTO_UPDATE_AT='${AUTO_UPDATE_AT}', falling back to 04:00"
  AUTO_UPDATE_AT="04:00"
fi
TAILSCALE_ENABLE_SERVE="0"
TAILSCALE_HTTPS_URL=""
TAILSCALE_NEEDS_LOGIN="0"
TAILSCALE_AUTH_INVALID="0"
TAILSCALE_AUTH_URL=""
HAPPIER_CLI_BIN=""
HAPPIER_CLI_NAME=""
HAPPIER_SERVER_PORT="${SERVER_PORT_RAW:-3005}"

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

# Install the Tailscale apt repo + package. Uses Tailscale's current keyring +
# .list files (fetched to temp and verified non-empty) so a transient network
# failure produces an actionable error instead of a half-written keyring/source.
install_tailscale_pkg() {
  local os_id="" os_codename=""
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || true
  os_id="${ID:-}"
  os_codename="${VERSION_CODENAME:-}"
  if [[ -z "${os_id}" || -z "${os_codename}" ]]; then
    msg_error "Could not determine OS id/codename from /etc/os-release for the Tailscale repo."
    return 1
  fi

  local base="https://pkgs.tailscale.com/stable/${os_id}/${os_codename}"
  local keyring_tmp="" list_tmp=""
  keyring_tmp="$(mktemp)"
  list_tmp="$(mktemp)"
  if ! curl -fsSL "${base}.noarmor.gpg" -o "${keyring_tmp}" || [[ ! -s "${keyring_tmp}" ]]; then
    rm -f "${keyring_tmp}" "${list_tmp}"
    msg_error "Failed to download the Tailscale signing key for ${os_id}/${os_codename}."
    return 1
  fi
  if ! curl -fsSL "${base}.tailscale-keyring.list" -o "${list_tmp}" || [[ ! -s "${list_tmp}" ]]; then
    rm -f "${keyring_tmp}" "${list_tmp}"
    msg_error "Failed to download the Tailscale apt source list for ${os_id}/${os_codename}."
    return 1
  fi
  install -m 0644 "${keyring_tmp}" /usr/share/keyrings/tailscale-archive-keyring.gpg
  install -m 0644 "${list_tmp}" /etc/apt/sources.list.d/tailscale.list
  rm -f "${keyring_tmp}" "${list_tmp}"

  $STD apt-get update -qq
  $STD apt-get install -y tailscale
  systemctl enable -q --now tailscaled
}

urlencode_component() {
  python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# Shared post-install "Next steps" output for both install methods (installers +
# from_source), so the step sequence/wording cannot drift between them.
#   $1 = auth-login command to display for the in-container daemon auth
#   $2 = daemon start/restart command shown after login, or "" when the daemon
#        starts automatically once authenticated (managed service WAIT_FOR_AUTH)
#   $3 = channel CLI name used for `server add` / `server set`
print_next_steps() {
  local auth_login_cmd="$1" daemon_start_cmd="$2" terminal_cli="$3"
  local hosted_webapp_url=""
  hosted_webapp_url="$(channel_hosted_webapp_url "${HAPPIER_CHANNEL}")"

  local client_server_url=""
  if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
    client_server_url="${PUBLIC_URL}"
  elif [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
    client_server_url="${TAILSCALE_HTTPS_URL}"
  elif [[ "${REMOTE_ACCESS}" == "tailscale" ]]; then
    client_server_url="<your-tailscale-https-url>"
  elif [[ "${SETUP_BIND}" == "loopback" ]]; then
    client_server_url="http://127.0.0.1:${HAPPIER_SERVER_PORT}"
  else
    client_server_url="http://${LOCAL_IP}:${HAPPIER_SERVER_PORT}"
  fi

  local client_webapp_url=""
  if [[ "${SERVE_UI}" == "1" ]]; then
    if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
      client_webapp_url="${PUBLIC_URL}"
    elif [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
      client_webapp_url="${TAILSCALE_HTTPS_URL}"
    elif [[ "${REMOTE_ACCESS}" == "tailscale" ]]; then
      client_webapp_url=""
    elif [[ "${SETUP_BIND}" == "loopback" ]]; then
      client_webapp_url="http://127.0.0.1:${HAPPIER_SERVER_PORT}"
    else
      client_webapp_url="http://${LOCAL_IP}:${HAPPIER_SERVER_PORT}"
    fi
  else
    client_webapp_url="${hosted_webapp_url}"
  fi

  echo -e "${INFO}${YW} Next steps:${CL}"
  echo -e "${TAB}${YW}1)${CL} Configure your app to use this server:"
  echo -e "${TAB}${TAB}${YW}Tip:${CL} easiest is the mobile app — scan the QR shown by 'auth login' (it auto-selects this server)."
  echo -e "${TAB}${TAB}${YW}Configure links:${CL}"
  if [[ "${client_server_url}" == "<"*">" ]]; then
    echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}happier://server?url=${client_server_url}${CL}"
    if [[ -n "${client_webapp_url}" ]]; then
      echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${client_webapp_url}/server?url=${client_server_url}&auto=1${CL}"
    fi
  else
    local client_server_url_enc=""
    client_server_url_enc="$(urlencode_component "${client_server_url}")"
    echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}happier://server?url=${client_server_url_enc}${CL}"
    if [[ -n "${hosted_webapp_url}" && "${client_webapp_url}" == "${hosted_webapp_url}" && "${client_server_url}" != https://* ]]; then
      echo -e "${TAB}${TAB}${TAB}${YW}Web app note:${CL} requires an HTTPS server URL (use Tailscale Serve or reverse proxy)."
    elif [[ -z "${client_webapp_url}" && "${HAPPIER_CHANNEL}" == "dev" ]]; then
      echo -e "${TAB}${TAB}${TAB}${YW}Dev lane note:${CL} there is no hosted web UI for the dev channel unless you serve the UI locally."
    elif [[ -n "${client_webapp_url}" ]]; then
      echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${client_webapp_url}/server?url=${client_server_url_enc}&auto=1${CL}"
    fi
  fi

  echo -e "${TAB}${YW}2)${CL} Sign in or create an account (recommended: mobile app)."

  if [[ "${INSTALL_TYPE}" == "devbox" && "${DAEMON_AUTH_DONE}" == "1" ]]; then
    if [[ "${AUTOSTART}" == "1" ]]; then
      echo -e "${TAB}${YW}3)${CL} Daemon is authenticated and running."
    else
      echo -e "${TAB}${YW}3)${CL} Daemon is authenticated. Autostart is off — start it when you want it running:"
      if [[ -n "${daemon_start_cmd}" ]]; then
        echo -e "${TAB}${TAB}${GATEWAY}${BGN}${daemon_start_cmd}${CL}"
      fi
    fi
  elif [[ "${INSTALL_TYPE}" == "devbox" ]]; then
    echo -e "${TAB}${YW}3)${CL} Authenticate the daemon running in this container:"
    if [[ "${REMOTE_ACCESS}" == "tailscale" && -z "${TAILSCALE_HTTPS_URL}" ]]; then
      echo -e "${TAB}${TAB}${YW}Note:${CL} you selected Tailscale but no HTTPS URL was detected yet."
      echo -e "${TAB}${TAB}${YW}First:${CL} enroll Tailscale and enable Serve (see commands above), then set the canonical URL:"
      if [[ "${SERVE_UI}" == "1" ]]; then
        echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}sudo -u happier -H ${terminal_cli} server set --server-url <your-tailscale-https-url> --local-server-url http://127.0.0.1:${HAPPIER_SERVER_PORT} --webapp-url <your-tailscale-https-url>${CL}"
      else
        echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}sudo -u happier -H ${terminal_cli} server set --server-url <your-tailscale-https-url> --local-server-url http://127.0.0.1:${HAPPIER_SERVER_PORT}${CL}"
      fi
    fi
    echo -e "${TAB}${TAB}${GATEWAY}${BGN}${auth_login_cmd}${CL}"
    if [[ -n "${daemon_start_cmd}" ]]; then
      echo -e "${TAB}${TAB}${YW}Then start the daemon:${CL}"
      echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${daemon_start_cmd}${CL}"
    fi
  else
    echo -e "${TAB}${YW}3)${CL} To connect a terminal/daemon from your laptop/desktop:"
    echo -e "${TAB}${TAB}${YW}a)${CL} Add/select this server in your CLI:"
    if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
      echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${terminal_cli} server add --server-url ${PUBLIC_URL} --use${CL}"
    elif [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
      echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${terminal_cli} server add --server-url ${TAILSCALE_HTTPS_URL} --use${CL}"
    elif [[ "${REMOTE_ACCESS}" == "tailscale" ]]; then
      echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${terminal_cli} server add --server-url <your-tailscale-https-url> --use${CL}"
    elif [[ "${SETUP_BIND}" == "loopback" ]]; then
      echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${terminal_cli} server add --server-url http://127.0.0.1:${HAPPIER_SERVER_PORT} --use${CL}"
    else
      echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${terminal_cli} server add --server-url http://${LOCAL_IP}:${HAPPIER_SERVER_PORT} --use${CL}"
    fi
    echo -e "${TAB}${TAB}${YW}b)${CL} Then run:"
    echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${terminal_cli} auth login${CL}"
  fi
}

# Write the in-container `update` helper. customize() points it at upstream
# community-scripts; repoint it at this fork. The generated helper reads
# INSTALLER_REPO/INSTALLER_REF at update time (default happier-dev/ProxmoxVE@main)
# and threads them through to ct/happier.sh, so a pinned install updates from the
# SAME ref instead of silently jumping to main. To pin: `INSTALLER_REF=<tag> update`.
write_update_helper() {
  cat >/usr/bin/update <<'UPDATEEOF'
#!/usr/bin/env bash
set -euo pipefail
REPO="${INSTALLER_REPO:-happier-dev/ProxmoxVE}"
REF="${INSTALLER_REF:-main}"
curl -fsSL "https://raw.githubusercontent.com/${REPO}/${REF}/ct/happier.sh" \
  | INSTALLER_REPO="${REPO}" INSTALLER_REF="${REF}" bash
UPDATEEOF
  chmod +x /usr/bin/update
}

# Resolve the channel-matched Happier CLI and store it in HAPPIER_CLI_NAME /
# HAPPIER_CLI_BIN, exiting on failure. Wraps the shared (non-fatal) resolver.
resolve_installed_cli_path_or_fail() {
  local cli_name
  cli_name="$(channel_cli_name "${HAPPIER_CHANNEL}")" || {
    msg_error "Invalid Happier channel: ${HAPPIER_CHANNEL}"
    exit 1
  }
  local candidate=""
  candidate="$(resolve_installed_cli_for_channel "${HAPPIER_CHANNEL}")" || {
    msg_error "Invalid Happier channel: ${HAPPIER_CHANNEL}"
    exit 1
  }
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
  # Supply chain: the official happier.dev installer is fetched over TLS and piped
  # to bash (same model as rustup/get.docker.com). The CLI binary it downloads is
  # verified by that installer; the UI bundle here is minisign + sha256 verified.
  # The bootstrap script itself is not pinned — accepted risk for the install flow.
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
  if [[ "${AUTO_UPDATE}" == "1" ]]; then
    relay_args+=(--auto-update --auto-update-at="${AUTO_UPDATE_AT}")
  fi
  if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
    relay_args+=(--env "HAPPIER_PUBLIC_SERVER_URL=${PUBLIC_URL}")
  fi

  local ui_current_dir=""
  if [[ "${SERVE_UI}" == "1" ]]; then
    msg_info "Installing Happier web UI bundle"
    ui_current_dir="$(install_managed_ui_bundle "${HAPPIER_CHANNEL}" install)"
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
    if ! install_tailscale_pkg; then
      msg_error "Tailscale installation failed. Check container network/DNS, then re-run."
      exit 1
    fi
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
  # No manual wait-for-auth write needed here: the managed CLI's `service install`
  # already injects HAPPIER_STACK_DAEMON_WAIT_FOR_AUTH=1 (see @happier-dev/stack
  # scripts/service.mjs), so the daemon waits for auth while the server/UI stay up.
  # (The from_source path sets it by hand only because its non-service nohup start
  # does not go through `service install`.)
  msg_info "Installing background service (devbox)"
  HOME="/home/happier" \
    HAPPIER_HOME_DIR="/home/happier/.happier" \
    $STD sudo -u happier -H "${HAPPIER_CLI_BIN}" --server proxmox service install --mode system --system-user happier --yes </dev/null
  msg_ok "Background service installed"
}

# Install the agent CLIs the daemon drives (claude, codex). npm-global so the
# binaries are on PATH for the happier user too. The installers path doesn't bring
# Node, so install it on demand when npm is missing (the from_source path already has it).
# Non-fatal: a failure here still lets the daemon be wired to a later manual install.
install_devbox_agents() {
  if [[ "${INSTALL_AGENTS}" != "1" ]]; then
    return 0
  fi
  if ! command -v npm >/dev/null 2>&1; then
    msg_info "Installing Node.js (required for agent CLIs)"
    NODE_VERSION="24" setup_nodejs
    msg_ok "Installed Node.js"
  fi
  if ! command -v npm >/dev/null 2>&1; then
    msg_warn "npm not available; skipping claude/codex install"
    return 0
  fi
  msg_info "Installing agent CLIs (claude, codex)"
  if $STD npm install -g @anthropic-ai/claude-code @openai/codex; then
    msg_ok "Installed agent CLIs"
  else
    msg_warn "Agent CLI install failed (non-fatal) — install claude/codex manually and re-run update"
  fi
}

# Write a chmod-600 systemd drop-in giving the daemon the agent paths (+ optional PAT).
# Discovers the daemon unit created by `service install --mode system`; if none is found
# yet, warns and skips rather than writing to a guessed path.
write_daemon_env_dropin() {
  local claude_path codex_path daemon_unit dropin_dir dropin
  claude_path="$(command -v claude || true)"
  codex_path="$(command -v codex || true)"

  if [[ -z "${claude_path}" && -z "${codex_path}" && -z "${DAEMON_GITHUB_PAT}" ]]; then
    msg_warn "No claude/codex found and no PAT provided; skipping daemon env drop-in"
    return 0
  fi

  daemon_unit="$(systemctl list-unit-files --no-legend 'happier-daemon*.service' 2>/dev/null | awk 'NR==1{print $1}')"
  if [[ -z "${daemon_unit}" ]]; then
    daemon_unit="$(systemctl list-units --all --no-legend 'happier-daemon*.service' 2>/dev/null | awk 'NR==1{print $1}')"
  fi
  if [[ -z "${daemon_unit}" ]]; then
    # No systemd unit (e.g. AUTOSTART=0 / manually-started daemon): a drop-in has nothing
    # to attach to, so print the exact env to set before starting the daemon manually
    # rather than silently dropping the wiring. (The PAT value is never printed.)
    msg_warn "No daemon systemd unit found (autostart off / manual start) — set the daemon env yourself before 'happier daemon start':"
    if [[ -n "${claude_path}" ]]; then echo "    export HAPPIER_CLAUDE_PATH=${claude_path}"; fi
    if [[ -n "${codex_path}" ]]; then echo "    export HAPPIER_CODEX_PATH=${codex_path}"; fi
    if [[ -n "${DAEMON_GITHUB_PAT}" ]]; then echo "    export GITHUB_PERSONAL_ACCESS_TOKEN=<the token you provided>"; fi
    return 0
  fi

  dropin_dir="/etc/systemd/system/${daemon_unit}.d"
  dropin="${dropin_dir}/10-happier-agents.conf"
  msg_info "Wiring daemon environment (${daemon_unit})"
  mkdir -p "${dropin_dir}"
  ( umask 077; {
    printf '[Service]\n'
    [[ -n "${claude_path}" ]] && printf 'Environment="HAPPIER_CLAUDE_PATH=%s"\n' "${claude_path}"
    [[ -n "${codex_path}" ]] && printf 'Environment="HAPPIER_CODEX_PATH=%s"\n' "${codex_path}"
    # NB: GitHub PATs are [A-Za-z0-9_] only; systemd Environment= treats % specially —
    # don't reuse this line verbatim for secrets that may contain % or ".
    [[ -n "${DAEMON_GITHUB_PAT}" ]] && printf 'Environment="GITHUB_PERSONAL_ACCESS_TOKEN=%s"\n' "${DAEMON_GITHUB_PAT}"
  } >"${dropin}" ) || true
  chmod 600 "${dropin}"
  $STD systemctl daemon-reload || true
  $STD systemctl restart "${daemon_unit}" || true
  msg_ok "Wired daemon environment"
}

# Resolve the best client-facing URL to show the user before the QR appears.
resolve_daemon_auth_server_url() {
  if [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
    printf '%s' "${TAILSCALE_HTTPS_URL}"
  elif [[ -n "${PUBLIC_URL}" ]]; then
    printf '%s' "${PUBLIC_URL}"
  elif [[ "${SETUP_BIND}" == "loopback" ]]; then
    # Loopback bind only listens on 127.0.0.1 — not reachable from a phone/LAN.
    printf '%s' "http://127.0.0.1:${HAPPIER_SERVER_PORT}"
  else
    printf '%s' "http://${LOCAL_IP}:${HAPPIER_SERVER_PORT}"
  fi
}

# Best-effort wait until a local TCP port accepts connections (server warmup).
# Non-fatal: returns 1 if it never comes up within the budget.
wait_for_local_port() {
  local port="$1" attempts="${2:-15}" i=1
  while ((i <= attempts)); do
    if timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# Interactively authenticate the daemon during install (devbox + UI + opt-in).
# Shows a QR code for the Happier mobile app. Best-effort: a 5-minute timeout
# skips, and Ctrl+C skips too — a local INT handler overrides the framework's
# global abort trap (on_interrupt -> exit 130) so the install continues, then
# restores it. Sets DAEMON_AUTH_DONE=1 on success.
# Args: the CLI command + args to run as the happier user.
run_daemon_auth_interactive() {
  local auth_url saved_int_trap rc=0 interrupted=0
  auth_url="$(resolve_daemon_auth_server_url)"

  # Mobile QR auth needs a URL the phone can reach. In loopback bind (Tailscale
  # mode) with no HTTPS URL yet, skip and let the user authenticate later.
  if [[ "${SETUP_BIND}" == "loopback" && "${auth_url}" != https://* ]]; then
    DAEMON_AUTH_DONE="0"
    msg_warn "Skipping interactive daemon auth: no phone-reachable URL yet. Set up Tailscale/HTTPS, then run 'auth login'."
    return 1
  fi

  # Give the server a moment to bind before showing the QR (best-effort).
  wait_for_local_port "${HAPPIER_SERVER_PORT}" 15 || true

  echo ""
  echo -e "${INFO}${YW} Authenticate your daemon now.${CL}"
  echo -e "${TAB}A QR code will appear — scan it with the Happier mobile app."
  echo -e "${TAB}The app needs to reach: ${BGN}${auth_url}${CL}"
  echo -e "${TAB}Press Ctrl+C to skip and continue the install."
  echo ""

  saved_int_trap="$(trap -p INT)"
  trap 'interrupted=1' INT
  timeout 300 sudo -u happier -H "$@" </dev/null || rc=$?
  if [[ -n "${saved_int_trap}" ]]; then eval "${saved_int_trap}"; else trap - INT; fi

  if ((interrupted)); then
    DAEMON_AUTH_DONE="0"
    msg_warn "Daemon auth interrupted; skipping (you can do it later)."
    return 1
  fi
  if [[ ${rc} -eq 0 ]]; then
    DAEMON_AUTH_DONE="1"
    msg_ok "Daemon authenticated"
    return 0
  fi

  DAEMON_AUTH_DONE="0"
  msg_warn "Daemon auth skipped (you can do it later)."
  return 1
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

    install_devbox_agents
    write_daemon_env_dropin
  fi

  # Post-install output: configure server → sign in/create → connect daemon/terminal.
  msg_ok "Install complete"
  RELAY_SERVICE_NAME="$(channel_relay_service_name "${HAPPIER_CHANNEL}")"
  CLIENT_CLI_NAME="${HAPPIER_CLI_NAME}"

  if [[ "${INSTALL_TYPE}" == "devbox" && "${SERVE_UI}" == "1" && "${DAEMON_AUTH}" == "1" ]]; then
    if run_daemon_auth_interactive "${HAPPIER_CLI_BIN}" auth login --method=mobile --no-open --start-if-needed; then
      if [[ "${AUTOSTART}" == "1" ]]; then
        restart_happier_unit "${RELAY_SERVICE_NAME}"
      fi
    fi
  fi

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

  DAEMON_START_CMD=""
  if [[ "${INSTALL_TYPE}" == "devbox" && "${AUTOSTART}" != "1" ]]; then
    # With autostart on, the managed service starts the daemon automatically once
    # authenticated (HAPPIER_STACK_DAEMON_WAIT_FOR_AUTH); only show a manual start otherwise.
    DAEMON_START_CMD="sudo -u happier -H ${CLIENT_CLI_NAME} daemon start"
  fi
  print_next_steps \
    "sudo -u happier -H ${CLIENT_CLI_NAME} auth login" \
    "${DAEMON_START_CMD}" \
    "${CLIENT_CLI_NAME}"

  motd_ssh
  customize

  # customize() points /usr/bin/update at community-scripts; repoint it at the fork.
  write_update_helper

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
if [[ -n "${SERVER_PORT_RAW}" ]]; then
  # from_source server binds HAPPIER_STACK_SERVER_PORT (not PORT); honor the override.
  SETUP_ENV+=("HAPPIER_STACK_SERVER_PORT=${HAPPIER_SERVER_PORT}")
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

# Pin the install to a concrete version: resolve the channel dist-tag once so the
# build is reproducible/logged and not subject to the tag moving mid-install.
STACK_PACKAGE_RESOLVED="${STACK_PACKAGE}"
if command -v npm >/dev/null 2>&1; then
  _resolved_stack_version="$(npm view "${STACK_PACKAGE}" version 2>/dev/null | tr -d '\r' | tail -n 1 || true)"
  if [[ -n "${_resolved_stack_version}" ]]; then
    STACK_PACKAGE_RESOLVED="@happier-dev/stack@${_resolved_stack_version}"
  fi
fi

msg_info "Installing Happier (hstack setup-from-source) — package: ${STACK_PACKAGE_RESOLVED}"
(
  # Avoid sudo inheriting an inaccessible cwd (e.g. /root) for the happier user.
  cd /home/happier || { msg_error "Failed to access /home/happier"; exit 1; }
  $STD sudo -u happier -H env "${SETUP_ENV[@]}" \
    npx --yes -p "${STACK_PACKAGE_RESOLVED}" hstack setup-from-source "${SETUP_ARGS[@]}" </dev/null
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
chmod 600 "$STACK_ENV_FILE"

set_env_kv() {
  local file="$1" key="$2" value="$3"
  local escaped
  # Escape the sed replacement metacharacters: backslash, ampersand, and the '|' delimiter.
  escaped="$(printf '%s' "$value" | sed -e 's/[\\&|]/\\&/g')"
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
if [[ -n "${SERVER_PORT_RAW}" ]]; then
  # Persist the port override so the from_source server actually binds it on start.
  set_env_kv "$STACK_ENV_FILE" "HAPPIER_STACK_SERVER_PORT" "${HAPPIER_SERVER_PORT}"
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
  if ! install_tailscale_pkg; then
    msg_error "Tailscale installation failed. Check container network/DNS, then re-run."
    exit 1
  fi
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
    restart_happier_unit "${STACK_LABEL}.service"
  fi
  msg_ok "Autostart enabled"
fi

# from_source devbox builds a daemon too: provision the agent CLIs and wire the daemon
# env drop-in, mirroring the installers path. Placed after the stack service is installed
# and STACK_ENV_FILE is written so the daemon unit exists for drop-in discovery (the helper
# skips-with-warn if none is found). Auto-update stays relay/installers-only (not added here).
if [[ "${INSTALL_TYPE}" == "devbox" ]]; then
  install_devbox_agents
  write_daemon_env_dropin
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
      restart_happier_unit "${STACK_LABEL}.service"
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

if [[ "${INSTALL_TYPE}" == "devbox" && "${SERVE_UI}" == "1" && "${DAEMON_AUTH}" == "1" ]]; then
  if run_daemon_auth_interactive "${HSTACK_BIN}" auth login --method=mobile --no-open --start-if-needed; then
    if [[ "${AUTOSTART}" == "1" ]]; then
      restart_happier_unit "${STACK_LABEL}.service"
    fi
  fi
fi

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
CLIENT_CLI_NAME="$(channel_cli_name "${HAPPIER_CHANNEL}")"
DAEMON_START_CMD=""
if [[ "${INSTALL_TYPE}" == "devbox" ]]; then
  if [[ "${AUTOSTART}" == "1" ]]; then
    DAEMON_START_CMD="sudo -u happier -H ${HSTACK_BIN} service restart --mode=system"
  else
    DAEMON_START_CMD="sudo -u happier -H ${HSTACK_BIN} start --restart"
  fi
fi
print_next_steps \
  "sudo -u happier -H ${HSTACK_BIN} auth login --method=mobile --no-open" \
  "${DAEMON_START_CMD}" \
  "${CLIENT_CLI_NAME}"

motd_ssh
customize

# customize() points /usr/bin/update at community-scripts; repoint it at the fork.
write_update_helper

cleanup_lxc
