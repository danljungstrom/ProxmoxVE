#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: happier-dev
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://happier.dev

# shellcheck disable=SC1091 # sourced from a runtime-provided string, not a file
source /dev/stdin <<<"${FUNCTIONS_FILE_PATH}"

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
# NB: this fetch/empty-check/source block must track ct/happier.sh's
# fetch_remote_script pattern; it stays inline here (bootstrap chicken-and-egg:
# the shared helper lives in the file being fetched).
# shellcheck disable=SC1091 # sourced from a runtime-fetched string, not a file
source /dev/stdin <<<"${HAPPIER_COMMON_FUNC}"

# Used by community-scripts helpers (e.g. motd_ssh in misc/install.func).
# shellcheck disable=SC2034 # consumed by the sourced framework, not this script
APP="Happier"
app="${app:-happier}"
# shellcheck disable=SC2034 # consumed by the sourced framework, not this script
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

INSTALL_TYPE="${HAPPIER_PVE_INSTALL_TYPE:-devbox}"             # devbox | server_only
SERVE_UI="${HAPPIER_PVE_SERVE_UI:-1}"                          # 1 | 0
AUTOSTART="${HAPPIER_PVE_AUTOSTART:-1}"                        # 1 | 0
REMOTE_ACCESS="${HAPPIER_PVE_REMOTE_ACCESS:-none}"             # none | proxy | tailscale
INSTALL_METHOD_RAW="${HAPPIER_PVE_INSTALL_METHOD:-installers}" # installers | from_source (aliases: auto|selfhost|legacy)
TAILSCALE_AUTHKEY="${HAPPIER_PVE_TAILSCALE_AUTHKEY:-}"         # optional
PUBLIC_URL_RAW="${HAPPIER_PVE_PUBLIC_URL:-}"                   # required when REMOTE_ACCESS=proxy
DAEMON_AUTH="${HAPPIER_PVE_DAEMON_AUTH:-0}"                    # 1 | 0 (interactive QR auth during install)
DAEMON_AUTH_DONE="0"
HAPPIER_CHANNEL_RAW="${HAPPIER_PVE_CHANNEL:-${HAPPIER_PVE_HSTACK_CHANNEL:-stable}}" # stable | preview | dev
STACK_PACKAGE_RAW="${HAPPIER_PVE_STACK_PACKAGE:-${HAPPIER_PVE_HSTACK_PACKAGE:-}}"   # e.g. @happier-dev/stack@latest
SERVER_PORT_RAW="${HAPPIER_PVE_SERVER_PORT:-}"                                      # optional explicit PORT override
INSTALL_AGENTS="${HAPPIER_PVE_INSTALL_AGENTS:-1}"                                   # 1 | 0 (install claude+codex on devbox)
DAEMON_GITHUB_PAT="${HAPPIER_PVE_GITHUB_PAT:-}"                                     # optional daemon GITHUB_PERSONAL_ACCESS_TOKEN
AUTO_UPDATE="${HAPPIER_PVE_AUTO_UPDATE:-0}"                                         # 1 | 0 (enable managed auto-update timer)
AUTO_UPDATE_AT="${HAPPIER_PVE_AUTO_UPDATE_AT:-04:00}"                               # HH:MM for the auto-update timer
is_valid_hhmm() { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }
if [[ "${AUTO_UPDATE}" == "1" ]] && ! is_valid_hhmm "${AUTO_UPDATE_AT}"; then
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

# Generic bounded poll: retry_until <attempts> <sleep_s> <cmd...> — runs cmd
# until it succeeds (rc 0) or attempts are exhausted (rc 1).
retry_until() {
  local attempts="$1" sleep_s="$2"
  shift 2
  local i=1
  while ((i <= attempts)); do
    if "$@"; then
      return 0
    fi
    sleep "${sleep_s}"
    i=$((i + 1))
  done
  return 1
}

# Value-producing (prints the URL), so it keeps its own loop rather than retry_until.
resolve_tailscale_https_url_with_retries() {
  local attempts="${1:-10}"
  local sleep_s="${2:-2}"
  local i=1
  local detected=""
  while ((i <= attempts)); do
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

_tailscale_online_probe() {
  "${TAILSCALE_BIN:-tailscale}" ip -4 >/dev/null 2>&1 || "${TAILSCALE_BIN:-tailscale}" ip -6 >/dev/null 2>&1
}
tailscale_wait_until_online() { retry_until "${1:-20}" "${2:-2}" _tailscale_online_probe; }

_systemd_unit_active_probe() { systemctl is-active --quiet "$1" >/dev/null 2>&1; }
wait_for_systemd_active() { retry_until "${2:-30}" "${3:-1}" _systemd_unit_active_probe "$1"; }

tailscale_status_json_field() {
  local key="$1"
  "${TAILSCALE_BIN:-tailscale}" status --json 2>/dev/null |
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('${key}',''))" 2>/dev/null || true
}

# Enroll this node with the pre-auth key (best-effort) and classify the outcome.
# Shared by the managed and from_source paths so the diagnostics cannot drift.
# Sets: TAILSCALE_BIN (pinned path); TAILSCALE_ENABLE_SERVE=1 only when the node
# actually came online; TAILSCALE_AUTH_INVALID/TAILSCALE_NEEDS_LOGIN/
# TAILSCALE_AUTH_URL for the epilogue guidance. Never fatal.
enroll_tailscale_node() {
  # Pin the binary path to avoid shell/MOTD output polluting command-path resolution.
  TAILSCALE_BIN="$(command -v tailscale 2>/dev/null || true)"
  [[ -z "${TAILSCALE_BIN}" ]] && TAILSCALE_BIN="/usr/bin/tailscale"
  # Services run as the happier user; make it an approved tailscale operator.
  "${TAILSCALE_BIN}" set --operator=happier >/dev/null 2>&1 || msg_warn "Could not set tailscale operator to happier (continuing)."

  [[ -z "${TAILSCALE_AUTHKEY}" ]] && return 0

  msg_info "Enrolling Tailscale (pre-auth key)"
  if ! wait_for_systemd_active tailscaled 30 1; then
    msg_warn "tailscaled service did not report active yet; continuing anyway."
  fi
  # The key is passed via a 600 temp file (`--auth-key=file:`), not argv, so it
  # never appears in /proc/*/cmdline during the up-to-120s enrollment window.
  local authkey_file=""
  authkey_file="$(mktemp)"
  chmod 600 "${authkey_file}"
  printf '%s' "${TAILSCALE_AUTHKEY}" >"${authkey_file}"
  local up_output="" up_exit=0
  local up_args=(up "--auth-key=file:${authkey_file}")
  if command -v timeout >/dev/null 2>&1; then
    up_output="$(timeout 120 "${TAILSCALE_BIN}" "${up_args[@]}" 2>&1)" || up_exit=$?
  else
    up_output="$("${TAILSCALE_BIN}" "${up_args[@]}" 2>&1)" || up_exit=$?
  fi
  rm -f "${authkey_file}"
  "${TAILSCALE_BIN}" set --operator=happier >/dev/null 2>&1 || true

  if printf '%s' "${up_output}" | grep -Eiq 'invalid key|not valid|expired|unauthorized'; then
    TAILSCALE_AUTH_INVALID="1"
    TAILSCALE_NEEDS_LOGIN="1"
    TAILSCALE_AUTH_URL="$(tailscale_status_json_field AuthURL)"
    msg_warn "Tailscale auth key was rejected."
    msg_warn "tailscale up output: $(printf '%s' "${up_output}" | tail -n 1)"
    msg_warn "Use a fresh reusable pre-auth key, or run tailscale up manually after install."
  elif ((up_exit == 124 || up_exit == 137)); then
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
    local ts_state=""
    ts_state="$(tailscale_status_json_field BackendState)"
    TAILSCALE_AUTH_URL="$(tailscale_status_json_field AuthURL)"
    msg_warn "Tailscale enrollment attempted, but node is not online yet (state: ${ts_state:-unknown})."
    if [[ -n "${TAILSCALE_AUTH_URL}" ]]; then
      TAILSCALE_NEEDS_LOGIN="1"
      msg_warn "Tailscale still needs login. Auth URL: ${TAILSCALE_AUTH_URL}"
      msg_warn "Your pre-auth key may be expired, one-time and already used, or not reusable."
    else
      msg_warn "Check Tailscale networking prerequisites (outbound access and /dev/net/tun availability)."
    fi
    if [[ -n "${up_output}" ]]; then
      msg_warn "tailscale up output: $(printf '%s' "${up_output}" | tail -n 1)"
    fi
  fi
  return 0
}

# Reset + create the Serve mapping for the local server port and resolve the
# HTTPS URL, retrying — cert/DNS readiness can lag enrollment by 1-2 minutes on
# fresh nodes. Shared by both install paths. Sets TAILSCALE_HTTPS_URL ("" when
# not detected); returns 1 only when the node is not even online. Never fatal.
enable_tailscale_serve_url() {
  msg_info "Waiting for Tailscale HTTPS URL (this can take a minute or two on fresh nodes)"
  if ! tailscale_wait_until_online 90 2; then
    local ts_state=""
    ts_state="$(tailscale_status_json_field BackendState)"
    TAILSCALE_AUTH_URL="$(tailscale_status_json_field AuthURL)"
    msg_warn "Tailscale is not online yet; skipping automatic Serve URL detection (state: ${ts_state:-unknown})."
    if [[ -n "${TAILSCALE_AUTH_URL}" ]]; then
      TAILSCALE_NEEDS_LOGIN="1"
      msg_warn "Tailscale still needs login. Auth URL: ${TAILSCALE_AUTH_URL}"
    fi
    return 1
  fi
  "${TAILSCALE_BIN:-tailscale}" serve reset >/dev/null 2>&1 || true
  local _try
  for _try in $(seq 1 45); do
    "${TAILSCALE_BIN:-tailscale}" serve --bg "http://127.0.0.1:${HAPPIER_SERVER_PORT}" >/dev/null 2>&1 || true
    TAILSCALE_HTTPS_URL="$(resolve_tailscale_https_url_with_retries 2 1 || true)"
    if [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
      break
    fi
    sleep 3
  done
  if [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
    msg_ok "Tailscale Serve enabled"
  else
    msg_ok "Tailscale Serve attempted (no HTTPS URL detected yet)"
  fi
  return 0
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
  # The install-time INSTALLER_REPO/REF are baked in as the DEFAULTS (env still
  # overrides at update time) — otherwise a pinned install silently updates from
  # the moving main branch, contradicting the documented pinning contract.
  cat >/usr/bin/update <<UPDATEEOF
#!/usr/bin/env bash
set -euo pipefail
REPO="\${INSTALLER_REPO:-${INSTALLER_REPO:-happier-dev/ProxmoxVE}}"
REF="\${INSTALLER_REF:-${INSTALLER_REF:-main}}"
curl -fsSL "https://raw.githubusercontent.com/\${REPO}/\${REF}/ct/happier.sh" \\
  | INSTALLER_REPO="\${REPO}" INSTALLER_REF="\${REF}" bash
UPDATEEOF
  chmod +x /usr/bin/update
}

# Shared access-URL epilogue for both install methods (loopback/LAN + proxy +
# detected Tailscale HTTPS URL). Method-specific tailscale recovery guidance
# stays at the call sites.
print_access_urls() {
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
  fi
}

# Interactive daemon auth when requested (devbox + served UI + opt-in), then a
# relay/service restart so the freshly-authenticated daemon is picked up.
#   $1 = CLI to run the auth login with, $2 = unit to restart on success.
run_daemon_auth_if_requested() {
  local auth_cli="$1" restart_unit="$2"
  [[ "${INSTALL_TYPE}" == "devbox" && "${SERVE_UI}" == "1" && "${DAEMON_AUTH}" == "1" ]] || return 0
  if run_daemon_auth_interactive "${auth_cli}" auth login --method=mobile --no-open --start-if-needed; then
    if [[ "${AUTOSTART}" == "1" ]]; then
      restart_happier_unit "${restart_unit}"
    fi
  fi
  return 0
}

# Shared install tail for both methods, so the ordering cannot drift.
finish_install() {
  motd_ssh
  customize
  # customize() points /usr/bin/update at community-scripts; repoint it at the fork.
  write_update_helper
  cleanup_lxc
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
  "" | auto | installers | installer | selfhost | self-host)
    INSTALL_METHOD="installers"
    ;;
  from_source | from-source | source | setup | setup-from-source | legacy)
    INSTALL_METHOD="from_source"
    ;;
  *)
    msg_error "Invalid HAPPIER_PVE_INSTALL_METHOD=${INSTALL_METHOD_RAW}. Use: installers | from_source."
    exit 1
    ;;
esac

PUBLIC_URL="$(normalize_url_no_trailing_slash "${PUBLIC_URL_RAW}")"
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
STACK_PACKAGE="$(channel_default_stack_package "${HAPPIER_CHANNEL}" "${STACK_PACKAGE}")"
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
  # NB: the env overrides MUST prefix the consuming `bash`, not `curl` — an env
  # prefix applies only to the first command of a pipeline, so putting it on the
  # curl side hands the bootstrap its $HOME defaults (/root/.happier), which the
  # happier service user cannot execute.
  curl -fsSL "https://happier.dev/install" |
    HAPPIER_PRODUCT="cli" \
      HAPPIER_INSTALL_DIR="/opt/happier/cli" \
      HAPPIER_BIN_DIR="/usr/local/bin" \
      HAPPIER_WITH_DAEMON="0" \
      HAPPIER_NO_PATH_UPDATE="1" \
      HAPPIER_NONINTERACTIVE="1" \
      $STD bash -s -- --channel "${HAPPIER_CHANNEL}"

  # The bootstrap creates INSTALL_DIR mode 700 (it assumes its $HOME/.happier
  # default, where private is right). With a system-wide /opt path the happier
  # service user must be able to traverse it to run the CLI.
  chmod 755 /opt/happier/cli 2>/dev/null || true

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
  # shellcheck disable=SC2016 # $HOME is intentionally literal (expanded at login, not here)
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
    # Capability probe: released CLIs may not know the auto-update flags yet
    # (`relay host install` rejects unknown arguments). Degrade with a warning
    # instead of failing the whole install.
    if "${HAPPIER_CLI_BIN}" relay host install --help 2>&1 | grep -q -- '--auto-update'; then
      relay_args+=(--auto-update --auto-update-at="${AUTO_UPDATE_AT}")
    else
      msg_warn "This Happier CLI version does not support --auto-update yet; skipping the auto-update timer (update manually or re-run update after a CLI upgrade)."
      AUTO_UPDATE="0"
    fi
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
  # Kept for ensure_relay_host_installed: the CLI's daemon `service install` has
  # been observed to remove the relay unit during its reconciliation on fresh
  # installs, and reinstalling needs the exact same argument set.
  RELAY_INSTALL_ARGS=("${relay_args[@]}")
  msg_ok "Installed Happier relay host"

  if [[ "${REMOTE_ACCESS}" == "tailscale" ]]; then
    msg_info "Installing Tailscale"
    if ! install_tailscale_pkg; then
      msg_error "Tailscale installation failed. Check container network/DNS, then re-run."
      exit 1
    fi
    msg_ok "Installed Tailscale"

    enroll_tailscale_node
    if [[ "${TAILSCALE_ENABLE_SERVE}" == "1" ]]; then
      enable_tailscale_serve_url || true
      if [[ -n "${TAILSCALE_HTTPS_URL}" && "${AUTOSTART}" == "1" ]]; then
        # Restart so the relay picks up the Tailscale URL for deep links/QR codes.
        "${HAPPIER_CLI_BIN}" relay host restart --mode system --channel "${HAPPIER_CHANNEL}" >/dev/null 2>&1 || true
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

  local local_api_url="http://127.0.0.1:${HAPPIER_SERVER_PORT}"
  local canonical_url=""
  if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
    canonical_url="${PUBLIC_URL}"
  elif [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
    canonical_url="${TAILSCALE_HTTPS_URL}"
  elif [[ "${REMOTE_ACCESS}" == "none" ]]; then
    canonical_url="http://${LOCAL_IP}:${HAPPIER_SERVER_PORT}"
  else
    canonical_url="${local_api_url}"
  fi

  local webapp_url=""
  if [[ "${SERVE_UI}" == "1" ]]; then
    webapp_url="${canonical_url}"
  else
    webapp_url="$(channel_hosted_webapp_url "${HAPPIER_CHANNEL}")"
  fi

  msg_info "Configuring Happier server profile (devbox)"
  local server_add_args=(server add --name "proxmox" --server-url "${canonical_url}" --use)
  if [[ "${canonical_url}" == "${local_api_url}" ]]; then
    :
  else
    server_add_args+=(--local-server-url "${local_api_url}")
  fi
  [[ -n "${webapp_url}" ]] && server_add_args+=(--webapp-url "${webapp_url}")
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
  # Runs as ROOT: current CLIs require root for --mode system (--system-user makes
  # the unit run as happier). The CLI's post-install "daemon became active" check
  # cannot pass before auth (WAIT_FOR_AUTH), so a non-zero exit here is expected —
  # treat it as success when the unit actually got installed.
  local svc_rc=0
  HOME="/home/happier" \
    HAPPIER_HOME_DIR="/home/happier/.happier" \
    $STD "${HAPPIER_CLI_BIN}" --server proxmox service install --mode system --system-user happier --yes </dev/null || svc_rc=$?
  if [[ "${svc_rc}" -ne 0 ]]; then
    if [[ -n "$(find_happier_daemon_unit)" ]]; then
      msg_warn "Background service installed; daemon stays inactive until authenticated (CLI activation check rc=${svc_rc})."
    else
      msg_error "Background service install failed (rc=${svc_rc}) and no happier-daemon unit was created."
      exit 1
    fi
  fi
  msg_ok "Background service installed"
}

# The CLI's daemon `service install` has been observed to remove/absorb the
# relay unit during reconciliation on fresh installs (vendor behavior varies by
# version). Reinstall the relay with the exact original arguments if its unit
# vanished; idempotent when everything is fine.
ensure_relay_host_installed() {
  local relay_unit=""
  relay_unit="$(channel_relay_service_name "${HAPPIER_CHANNEL}")"
  if systemctl list-unit-files --no-legend "${relay_unit}.service" 2>/dev/null | grep -q .; then
    return 0
  fi
  msg_warn "Relay unit ${relay_unit} missing after daemon service install; reinstalling the relay host."
  $STD "${HAPPIER_CLI_BIN}" "${RELAY_INSTALL_ARGS[@]}" </dev/null || true
  restart_happier_unit "${relay_unit}"
}

# Install the agent CLIs the daemon drives.
# - claude: Anthropic's native installer, run as the happier user — the vendor-
#   recommended method (Anthropic warns against root npm globals, and a root-owned
#   global dir would break claude's self-update for the happier user). Lands in
#   ~happier/.local/bin/claude, which the installer wires onto the user's PATH.
# - codex: npm global install (the vendor-documented method). Node 24 is installed
#   on demand for it — the installers path doesn't bring Node (from_source does).
# Non-fatal throughout: a failure still lets the daemon be wired to a later manual install.
install_devbox_agents() {
  if [[ "${INSTALL_AGENTS}" != "1" ]]; then
    return 0
  fi

  msg_info "Installing claude (native installer, as happier)"
  if $STD sudo -u happier -H bash -c 'curl -fsSL https://claude.ai/install.sh | bash'; then
    msg_ok "Installed claude"
  else
    msg_warn "claude install failed (non-fatal) — install it manually and re-run update"
  fi

  if ! command -v npm >/dev/null 2>&1; then
    msg_info "Installing Node.js (required for codex)"
    # Guarded: setup_nodejs returns non-zero on apt/repo failures and would otherwise
    # abort the whole install via the ERR trap, contradicting the non-fatal contract.
    if NODE_VERSION="24" setup_nodejs; then
      msg_ok "Installed Node.js"
    else
      msg_warn "Node.js install failed (non-fatal) — skipping codex install"
      return 0
    fi
  fi
  if ! command -v npm >/dev/null 2>&1; then
    msg_warn "npm not available; skipping codex install"
    return 0
  fi
  msg_info "Installing codex (npm)"
  if $STD npm install -g @openai/codex; then
    msg_ok "Installed codex"
  else
    msg_warn "codex install failed (non-fatal) — install it manually and re-run update"
  fi
}

# Write a chmod-600 systemd drop-in giving the daemon the agent paths (+ optional PAT).
# Discovers the daemon unit created by `service install --mode system`; if none is found
# yet, warns and skips rather than writing to a guessed path.
write_daemon_env_dropin() {
  local claude_path codex_path daemon_unit dropin_dir dropin envfile
  claude_path="$(command -v claude || true)"
  # The native installer puts claude in the happier user's ~/.local/bin, which
  # root's PATH does not include.
  if [[ -z "${claude_path}" && -x /home/happier/.local/bin/claude ]]; then
    claude_path="/home/happier/.local/bin/claude"
  fi
  codex_path="$(command -v codex || true)"

  # GitHub PATs are [A-Za-z0-9_] only; anything else would produce an unparseable
  # env file (and is almost certainly a paste error), so refuse it up front.
  if [[ -n "${DAEMON_GITHUB_PAT}" && ! "${DAEMON_GITHUB_PAT}" =~ ^[A-Za-z0-9_]+$ ]]; then
    msg_warn "Provided GitHub PAT contains characters outside [A-Za-z0-9_]; skipping PAT wiring"
    DAEMON_GITHUB_PAT=""
  fi

  if [[ -z "${claude_path}" && -z "${codex_path}" && -z "${DAEMON_GITHUB_PAT}" ]]; then
    msg_warn "No claude/codex found and no PAT provided; skipping daemon env drop-in"
    return 0
  fi

  daemon_unit="$(find_happier_daemon_unit)"
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
  # The PAT goes in a separate root-only EnvironmentFile, NOT an Environment= directive:
  # unit Environment= values are exposed to unprivileged users over D-Bus
  # (systemctl show <unit> -p Environment), which would defeat the chmod 600.
  # systemd only parses *.conf in the drop-in dir, so the .env file beside it is
  # plain data referenced by path, never a unit fragment.
  envfile="${dropin_dir}/10-happier-agents.env"
  msg_info "Wiring daemon environment (${daemon_unit})"
  mkdir -p "${dropin_dir}"
  # NB: errexit is suspended inside an `if !` condition, so failures must be
  # chained explicitly with `|| exit 1` for the subshell to report them.
  if ! (
    umask 077
    {
      printf '[Service]\n'
      if [[ -n "${claude_path}" ]]; then printf 'Environment="HAPPIER_CLAUDE_PATH=%s"\n' "${claude_path}"; fi
      if [[ -n "${codex_path}" ]]; then printf 'Environment="HAPPIER_CODEX_PATH=%s"\n' "${codex_path}"; fi
      if [[ -n "${DAEMON_GITHUB_PAT}" ]]; then printf 'EnvironmentFile=%s\n' "${envfile}"; fi
    } >"${dropin}" || exit 1
    if [[ -n "${DAEMON_GITHUB_PAT}" ]]; then
      printf 'GITHUB_PERSONAL_ACCESS_TOKEN=%s\n' "${DAEMON_GITHUB_PAT}" >"${envfile}" || exit 1
    else
      rm -f "${envfile}"
    fi
  ); then
    msg_warn "Failed to write the daemon env drop-in (disk full/read-only?); skipping daemon env wiring"
    rm -f "${dropin}" "${envfile}"
    return 0
  fi
  chmod 600 "${dropin}"
  [[ -f "${envfile}" ]] && chmod 600 "${envfile}"
  local wiring_rc=0
  $STD systemctl daemon-reload || wiring_rc=$?
  $STD systemctl restart "${daemon_unit}" || wiring_rc=$?
  if [[ "${wiring_rc}" -eq 0 ]]; then
    msg_ok "Wired daemon environment"
  else
    msg_warn "Daemon env drop-in written, but daemon-reload/restart failed (rc=${wiring_rc}) — check: systemctl status ${daemon_unit}"
  fi
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
_local_port_open_probe() { timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }
wait_for_local_port() { retry_until "${2:-15}" 1 _local_port_open_probe "$1"; }

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
      ensure_relay_host_installed
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

  run_daemon_auth_if_requested "${HAPPIER_CLI_BIN}" "${RELAY_SERVICE_NAME}"

  print_access_urls
  if [[ -z "${TAILSCALE_HTTPS_URL}" && "${REMOTE_ACCESS}" == "tailscale" ]]; then
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

  finish_install
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
  cd /home/happier || {
    msg_error "Failed to access /home/happier"
    exit 1
  }
  $STD sudo -u happier -H env "${SETUP_ENV[@]}" \
    npx --yes -p "${STACK_PACKAGE_RESOLVED}" hstack setup-from-source "${SETUP_ARGS[@]}" </dev/null
)
msg_ok "Installed Happier (hstack setup-from-source)"

# Resolve actual hstack binary and paths. Some setups may not use the default stack/workdir.
HSTACK_BIN="/home/happier/.happier-stack/bin/hstack"
if [[ ! -x "${HSTACK_BIN}" ]]; then
  HSTACK_BIN="$(sudo -u happier -H bash -lc 'command -v hstack || true' | tr -d '\r')"
fi
if [[ -z "${HSTACK_BIN}" || ! -x "${HSTACK_BIN}" ]]; then
  msg_error "hstack binary not found after setup."
  exit 1
fi

HSTACK_HOME_DIR="/home/happier/.happier-stack"
STACK_NAME="main"
STACK_LABEL="dev.happier.stack"
STACK_ENV_FILE="/home/happier/.happier/stacks/${STACK_NAME}/env"
resolve_hstack_layout "${HSTACK_BIN}"
[[ -n "${HSTACK_WHERE_HOME}" ]] && HSTACK_HOME_DIR="${HSTACK_WHERE_HOME}"
[[ -n "${HSTACK_WHERE_NAME}" ]] && STACK_NAME="${HSTACK_WHERE_NAME}"
[[ -n "${HSTACK_WHERE_LABEL}" ]] && STACK_LABEL="${HSTACK_WHERE_LABEL}"
[[ -n "${HSTACK_WHERE_ENV}" ]] && STACK_ENV_FILE="${HSTACK_WHERE_ENV}"
if [[ ! -f "${STACK_ENV_FILE}" ]]; then
  _fallback_env="$(find /home/happier/.happier/stacks -mindepth 2 -maxdepth 2 -type f -name env 2>/dev/null | head -n 1 || true)"
  [[ -n "${_fallback_env}" ]] && STACK_ENV_FILE="${_fallback_env}"
fi
HAPPIER_HOME="$(getent passwd happier | cut -d: -f6 | tr -d '\r' || true)"
[[ -z "${HAPPIER_HOME}" ]] && HAPPIER_HOME="/home/happier"
mkdir -p "$(dirname "${STACK_ENV_FILE}")"
touch "${STACK_ENV_FILE}"
chown happier:happier "${STACK_ENV_FILE}"
chmod 600 "${STACK_ENV_FILE}"

set_env_kv() {
  local file="$1" key="$2" value="$3"
  local escaped
  # Escape the sed replacement metacharacters: backslash, ampersand, and the '|' delimiter.
  escaped="$(printf '%s' "${value}" | sed -e 's/[\\&|]/\\&/g')"
  if grep -q "^${key}=" "${file}"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "${file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >>"${file}"
  fi
}

remove_env_kv() {
  local file="$1" key="$2"
  [[ -f "${file}" ]] || return 0
  sed -i "/^${key}=/d" "${file}"
}

# (tailscale_wait_until_online / tailscale_status_json_field / wait_for_systemd_active
#  are defined in the shared helper section near the top of this file.)

set_env_kv "${STACK_ENV_FILE}" "HAPPIER_SERVER_HOST" "${SERVER_HOST}"
set_env_kv "${STACK_ENV_FILE}" "HAPPIER_STACK_BIND_MODE" "${SETUP_BIND}"
if [[ "${INSTALL_TYPE}" == "server_only" ]]; then
  set_env_kv "${STACK_ENV_FILE}" "HAPPIER_STACK_DAEMON" "0"
fi
if [[ "${SERVE_UI}" != "1" ]]; then
  set_env_kv "${STACK_ENV_FILE}" "HAPPIER_STACK_SERVE_UI" "0"
fi
if [[ "${INSTALL_TYPE}" == "devbox" ]]; then
  set_env_kv "${STACK_ENV_FILE}" "HAPPIER_STACK_DAEMON_WAIT_FOR_AUTH" "1"
fi
if [[ -n "${SERVER_PORT_RAW}" ]]; then
  # Persist the port override so the from_source server actually binds it on start.
  set_env_kv "${STACK_ENV_FILE}" "HAPPIER_STACK_SERVER_PORT" "${HAPPIER_SERVER_PORT}"
fi

# Set a best-effort server URL early so autostart/manual start uses it on first boot.
get_lxc_ip
if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
  set_env_kv "${STACK_ENV_FILE}" "HAPPIER_STACK_SERVER_URL" "${PUBLIC_URL}"
  set_env_kv "${STACK_ENV_FILE}" "HAPPIER_PUBLIC_SERVER_URL" "${PUBLIC_URL}"
elif [[ "${REMOTE_ACCESS}" != "tailscale" ]]; then
  set_env_kv "${STACK_ENV_FILE}" "HAPPIER_STACK_SERVER_URL" "http://${LOCAL_IP}:${HAPPIER_SERVER_PORT}"
  set_env_kv "${STACK_ENV_FILE}" "HAPPIER_PUBLIC_SERVER_URL" "http://${LOCAL_IP}:${HAPPIER_SERVER_PORT}"
fi
if [[ "${SERVE_UI}" == "1" && "${REMOTE_ACCESS}" == "proxy" ]]; then
  # Advertise that terminal-connect web UI is served from this same origin.
  set_env_kv "${STACK_ENV_FILE}" "HAPPIER_WEBAPP_URL" "${PUBLIC_URL}"
elif [[ "${SERVE_UI}" == "1" && "${REMOTE_ACCESS}" != "tailscale" && "${SETUP_BIND}" == "lan" ]]; then
  # Local-only installs can still serve the UI (but will not be reachable off-LAN without HTTPS).
  set_env_kv "${STACK_ENV_FILE}" "HAPPIER_WEBAPP_URL" "http://${LOCAL_IP}:${HAPPIER_SERVER_PORT}"
elif [[ "${SERVE_UI}" != "1" ]]; then
  # Prefer the hosted web app when the local UI is not served.
  FROM_SOURCE_HOSTED_WEBAPP_URL="$(channel_hosted_webapp_url "${HAPPIER_CHANNEL}")"
  if [[ -n "${FROM_SOURCE_HOSTED_WEBAPP_URL}" ]]; then
    set_env_kv "${STACK_ENV_FILE}" "HAPPIER_WEBAPP_URL" "${FROM_SOURCE_HOSTED_WEBAPP_URL}"
  else
    remove_env_kv "${STACK_ENV_FILE}" "HAPPIER_WEBAPP_URL"
  fi
fi

if [[ "${SERVE_UI}" == "1" ]]; then
  msg_info "Building Happier web UI (required to serve UI)"
  $STD sudo -u happier -H "${HSTACK_BIN}" build --no-tauri </dev/null
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

  enroll_tailscale_node
  set_env_kv "${STACK_ENV_FILE}" "HAPPIER_STACK_TAILSCALE_BIN" "${TAILSCALE_BIN}"
  set_env_kv "${STACK_ENV_FILE}" "HAPPIER_STACK_TAILSCALE_SERVE" "1"
fi

if [[ "${AUTOSTART}" == "1" ]]; then
  # Ensure the logs directory exists before the systemd service starts,
  # otherwise StandardOutput=append:... fails with status=209/STDOUT.
  mkdir -p "$(dirname "${STACK_ENV_FILE}")/logs"
  chown -R happier:happier "$(dirname "${STACK_ENV_FILE}")/logs"
  msg_info "Enabling autostart (systemd system service)"
  $STD env HOME="${HAPPIER_HOME}" \
    HAPPIER_STACK_HOME_DIR="${HSTACK_HOME_DIR}" \
    HAPPIER_STACK_ENV_FILE="${STACK_ENV_FILE}" \
    "${HSTACK_BIN}" service install --mode=system --system-user=happier

  # hstack currently writes WorkingDirectory=%h for system services.
  # For system units this can resolve to /root; force the explicit happier home.
  SYSTEMD_UNIT_PATH="/etc/systemd/system/${STACK_LABEL}.service"
  if [[ -f "${SYSTEMD_UNIT_PATH}" ]]; then
    sed -i "s|^WorkingDirectory=.*|WorkingDirectory=${HAPPIER_HOME}|" "${SYSTEMD_UNIT_PATH}"
    if ! grep -q '^User=happier$' "${SYSTEMD_UNIT_PATH}"; then
      sed -i '/^\[Service\]/a User=happier' "${SYSTEMD_UNIT_PATH}"
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
  sudo -u happier -H "${HSTACK_BIN}" tailscale enable >/dev/null 2>&1 || true

  enable_tailscale_serve_url || true

  if [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
    set_env_kv "${STACK_ENV_FILE}" "HAPPIER_STACK_SERVER_URL" "${TAILSCALE_HTTPS_URL}"
    set_env_kv "${STACK_ENV_FILE}" "HAPPIER_PUBLIC_SERVER_URL" "${TAILSCALE_HTTPS_URL}"
    if [[ "${SERVE_UI}" == "1" ]]; then
      set_env_kv "${STACK_ENV_FILE}" "HAPPIER_WEBAPP_URL" "${TAILSCALE_HTTPS_URL}"
    fi
    # The service was started earlier without the Tailscale URL; restart so
    # it picks up the correct HAPPIER_STACK_SERVER_URL for deep links/QR codes.
    if [[ "${AUTOSTART}" == "1" ]]; then
      restart_happier_unit "${STACK_LABEL}.service"
    fi
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

run_daemon_auth_if_requested "${HSTACK_BIN}" "${STACK_LABEL}.service"

print_access_urls
if [[ -z "${TAILSCALE_HTTPS_URL}" && "${REMOTE_ACCESS}" == "tailscale" ]]; then
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

finish_install
