# Happier Devbox Agents + Hands-off Updates — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a Happier `devbox` install produce a working agent daemon (claude/codex wired, optionally installed) and make updates hands-off (opt-in auto-update timer) and complete (daemon restarted on update).

**Architecture:** Host-side `ct/happier.sh:app_questions` collects new toggles/secret and exports them as `HAPPIER_PVE_*` env (inherited into the container via the existing lxc-attach passthrough). In-container `install/happier-install.sh` reads them: appends `--auto-update` flags to the managed relay install, installs the agent CLIs, and writes a `chmod 600` systemd drop-in with the daemon env. `ct/happier.sh:update_script` gains a daemon restart.

**Tech Stack:** Bash (Proxmox community-scripts helper model), whiptail, systemd drop-ins, npm-global agent installs. No unit-test harness in this domain — verification per task is `bash -n` + `shellcheck` (the repo's `happier-lint` workflow) plus the LXC integration matrix from the spec (`docs/superpowers/specs/2026-06-27-happier-installer-devbox-updates-design.md`).

**Branch:** `feat/devbox-agents-autoupdate` (already created off `daemon-auth`; the spec is committed there).

**Conventions to follow (existing in these files):** `msg_info`/`msg_ok`/`msg_warn` for output; `$STD` to silence verbose cmds; `sudo -u happier -H` for happier-user actions; `printf` (never heredoc) for writing secret-bearing files; `chmod 600` for secrets; best-effort steps guarded with `|| true` so the ERR trap doesn't abort.

---

## File structure

- `install/happier-install.sh` — config vars (new `HAPPIER_PVE_*` reads), `install_managed_relay_runtime` (auto-update flags), two new helpers `install_devbox_agents` + `write_daemon_env_dropin`, and their call site in the devbox flow.
- `ct/happier.sh` — `app_questions` (new whiptail toggles + PAT passwordbox + exports), `update_script` (daemon restart).
- `json/happier.json` — one `notes` entry documenting the new knobs + RAM note.

---

## Task 1: New config vars (install side)

**Files:**
- Modify: `install/happier-install.sh` (after line 71, the `SERVER_PORT_RAW` config var)

- [ ] **Step 1: Add the four new env reads**

After the existing `SERVER_PORT_RAW="${HAPPIER_PVE_SERVER_PORT:-}"` line, add:

```bash
INSTALL_AGENTS="${HAPPIER_PVE_INSTALL_AGENTS:-1}"      # 1 | 0 (install claude+codex on devbox)
DAEMON_GITHUB_PAT="${HAPPIER_PVE_GITHUB_PAT:-}"        # optional daemon GITHUB_PERSONAL_ACCESS_TOKEN
AUTO_UPDATE="${HAPPIER_PVE_AUTO_UPDATE:-0}"            # 1 | 0 (enable managed auto-update timer)
AUTO_UPDATE_AT="${HAPPIER_PVE_AUTO_UPDATE_AT:-04:00}"  # HH:MM for the auto-update timer
```

- [ ] **Step 2: Validate the time format**

Immediately below the block above, add a guard that falls back on a bad value (per spec error-handling):

```bash
if [[ "${AUTO_UPDATE}" == "1" && ! "${AUTO_UPDATE_AT}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
  msg_warn "Invalid HAPPIER_PVE_AUTO_UPDATE_AT='${AUTO_UPDATE_AT}', falling back to 04:00"
  AUTO_UPDATE_AT="04:00"
fi
```

- [ ] **Step 3: Syntax check**

Run: `bash -n install/happier-install.sh`
Expected: no output (exit 0).

- [ ] **Step 4: Commit**

```bash
git add install/happier-install.sh
git commit -m "feat(happier): read new devbox/auto-update install knobs"
```

---

## Task 2: Auto-update flags on the managed relay install

**Files:**
- Modify: `install/happier-install.sh:install_managed_relay_runtime` (the `relay_args` block, around line 500-507)

- [ ] **Step 1: Append the flags when enabled**

In `install_managed_relay_runtime`, after the `SERVER_PORT_RAW` `relay_args+=(...)` block (line 502-504) and before the `REMOTE_ACCESS` block, add:

```bash
  if [[ "${AUTO_UPDATE}" == "1" ]]; then
    relay_args+=(--auto-update --auto-update-at="${AUTO_UPDATE_AT}")
  fi
```

- [ ] **Step 2: Syntax check**

Run: `bash -n install/happier-install.sh`
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add install/happier-install.sh
git commit -m "feat(happier): enable managed auto-update timer when opted in"
```

Satisfies LXC case 3 (auto-update timer active/absent).

---

## Task 3: Agent install helper

**Files:**
- Modify: `install/happier-install.sh` (add helper after `install_devbox_background_service`, i.e. after line 618)

- [ ] **Step 1: Add `install_devbox_agents`**

```bash
# Install the agent CLIs the daemon drives (claude, codex). Node is already present
# on the devbox path. npm-global so the binaries are on PATH for the happier user too.
# Non-fatal: a failure here still lets the daemon be wired to a later manual install.
install_devbox_agents() {
  if [[ "${INSTALL_AGENTS}" != "1" ]]; then
    return 0
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
```

- [ ] **Step 2: Syntax check**

Run: `bash -n install/happier-install.sh`
Expected: exit 0.

- [ ] **Step 3: Commit (with Task 4 — keep the devbox-provisioning pair in one commit; commit after Task 4)**

---

## Task 4: Daemon env drop-in helper

**Files:**
- Modify: `install/happier-install.sh` (add helper after `install_devbox_agents`)

- [ ] **Step 1: Add `write_daemon_env_dropin`**

```bash
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
    msg_warn "Daemon systemd unit not found; skipping env drop-in (set HAPPIER_CLAUDE_PATH/HAPPIER_CODEX_PATH/GITHUB_PERSONAL_ACCESS_TOKEN on the daemon manually)"
    return 0
  fi

  dropin_dir="/etc/systemd/system/${daemon_unit}.d"
  dropin="${dropin_dir}/10-happier-agents.conf"
  msg_info "Wiring daemon environment (${daemon_unit})"
  mkdir -p "${dropin_dir}"
  {
    printf '[Service]\n'
    [[ -n "${claude_path}" ]] && printf 'Environment="HAPPIER_CLAUDE_PATH=%s"\n' "${claude_path}"
    [[ -n "${codex_path}" ]] && printf 'Environment="HAPPIER_CODEX_PATH=%s"\n' "${codex_path}"
    [[ -n "${DAEMON_GITHUB_PAT}" ]] && printf 'Environment="GITHUB_PERSONAL_ACCESS_TOKEN=%s"\n' "${DAEMON_GITHUB_PAT}"
  } >"${dropin}"
  chmod 600 "${dropin}"
  $STD systemctl daemon-reload || true
  $STD systemctl restart "${daemon_unit}" || true
  msg_ok "Wired daemon environment"
}
```

- [ ] **Step 2: Call both helpers in the devbox flow**

Find the call site of `install_devbox_background_service` (grep: `grep -n 'install_devbox_background_service$' install/happier-install.sh` — the invocation, not the definition). Immediately after that call, add:

```bash
  install_devbox_agents
  write_daemon_env_dropin
```

Match the surrounding indentation. (Both are no-ops/safe outside devbox because the call site is already inside the devbox branch; if the call site is not clearly devbox-gated, wrap the two calls in `if [[ "${INSTALL_TYPE}" == "devbox" ]]; then ... fi`.)

- [ ] **Step 3: Syntax check**

Run: `bash -n install/happier-install.sh && grep -n 'install_devbox_agents\|write_daemon_env_dropin' install/happier-install.sh`
Expected: exit 0; shows the two definitions + the two call-site invocations.

- [ ] **Step 4: Commit (Tasks 3+4 together)**

```bash
git add install/happier-install.sh
git commit -m "feat(happier): provision devbox agents + wire daemon env drop-in"
```

Satisfies LXC cases 1 and 2 (agents on PATH; drop-in with paths/PAT at mode 600).

---

## Task 5: Host prompts + exports (ct/happier.sh)

**Files:**
- Modify: `ct/happier.sh:app_questions` (var defaults around line 168-176; add prompts near the existing toggles; exports near the existing `export HAPPIER_PVE_*`)

- [ ] **Step 1: Add defaults**

In `app_questions`, alongside the existing `HAPPIER_PVE_*` initializations (after `HAPPIER_PVE_STACK_PACKAGE=...`, ~line 176), add:

```bash
  HAPPIER_PVE_INSTALL_AGENTS="1"
  HAPPIER_PVE_GITHUB_PAT=""
  HAPPIER_PVE_AUTO_UPDATE="0"
  HAPPIER_PVE_AUTO_UPDATE_AT="04:00"
```

- [ ] **Step 2: Add the devbox agent toggle**

Inside the existing devbox-gated section (reuse the `[[ "$HAPPIER_PVE_INSTALL_TYPE" == "devbox" ... ]]` block near line 245, or add a `devbox`-gated block). Add:

```bash
  if [[ "$HAPPIER_PVE_INSTALL_TYPE" == "devbox" ]]; then
    if (whiptail --backtitle "$BACKTITLE" --title "AGENT CLIs" --yesno \
      "\nInstall the claude and codex CLIs now?\n\nThe daemon needs them to run agent sessions. Choose No if you'll install them yourself.\n" 12 72); then
      HAPPIER_PVE_INSTALL_AGENTS="1"
    else
      HAPPIER_PVE_INSTALL_AGENTS="0"
    fi
    HAPPIER_PVE_GITHUB_PAT=$(
      whiptail --backtitle "$BACKTITLE" --title "DAEMON GITHUB PAT" --passwordbox \
        "\nOptional: GitHub Personal Access Token for the daemon's git operations.\n\nLeave blank to skip (you can add it later)." 12 72 3>&1 1>&2 2>&3
    ) || HAPPIER_PVE_GITHUB_PAT=""
  fi
```

- [ ] **Step 3: Add the auto-update toggle**

After the agent block (still in `app_questions`), add:

```bash
  if (whiptail --backtitle "$BACKTITLE" --title "AUTO-UPDATE" --yesno \
    "\nEnable automatic updates?\n\nInstalls Happier's built-in updater timer (signature-verified, atomic, health-checked, auto-rollback). Default: No.\n" 13 72 --defaultno); then
    HAPPIER_PVE_AUTO_UPDATE="1"
    HAPPIER_PVE_AUTO_UPDATE_AT=$(
      whiptail --backtitle "$BACKTITLE" --title "AUTO-UPDATE TIME" --inputbox \
        "\nDaily update time (HH:MM, 24h):" 10 60 "04:00" 3>&1 1>&2 2>&3
    ) || HAPPIER_PVE_AUTO_UPDATE_AT="04:00"
  else
    HAPPIER_PVE_AUTO_UPDATE="0"
  fi
```

- [ ] **Step 4: Export the new vars**

Where the existing `export HAPPIER_PVE_*` statements are (near line 277), add:

```bash
  export HAPPIER_PVE_INSTALL_AGENTS HAPPIER_PVE_GITHUB_PAT HAPPIER_PVE_AUTO_UPDATE HAPPIER_PVE_AUTO_UPDATE_AT
```

- [ ] **Step 5: Syntax check**

Run: `bash -n ct/happier.sh`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add ct/happier.sh
git commit -m "feat(happier): prompt for devbox agents, daemon PAT, and auto-update"
```

---

## Task 6: Restart the daemon on update

**Files:**
- Modify: `ct/happier.sh:update_script` (the managed/installers branch, after the relay restart at line 92)

- [ ] **Step 1: Add a daemon restart after the relay restart**

After `restart_happier_unit "$(channel_relay_service_name "${installer_channel}")"` (line 92), add:

```bash
    # Devbox: the relay restart above does not cycle the daemon, so a CLI self-update
    # leaves the running daemon on the old CLI. Restart it (no-op for server_only).
    if "${cli_bin}" daemon status >/dev/null 2>&1; then
      "${cli_bin}" daemon restart >/dev/null 2>&1 || true
    else
      systemctl restart 'happier-daemon*.service' >/dev/null 2>&1 || true
    fi
```

(Confirm `cli_bin` is the variable name in scope at that point — grep around line 86 shows `"${cli_bin}" self update`; reuse it. If it is named differently, use that name.)

- [ ] **Step 2: Syntax check**

Run: `bash -n ct/happier.sh`
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add ct/happier.sh
git commit -m "fix(happier): restart the daemon on devbox update so it picks up the new CLI"
```

Satisfies LXC case 4 (relay + daemon both restart on update).

---

## Task 7: Document the new knobs

**Files:**
- Modify: `json/happier.json` (the `notes` array)

- [ ] **Step 1: Add a notes entry**

Append one object to the `notes` array (mind the trailing comma on the previous entry):

```json
        {
            "text": "Devbox extras (optional): HAPPIER_PVE_INSTALL_AGENTS=1 installs claude+codex; HAPPIER_PVE_GITHUB_PAT sets the daemon's GitHub token; HAPPIER_PVE_AUTO_UPDATE=1 (+HAPPIER_PVE_AUTO_UPDATE_AT=HH:MM, default 04:00) enables the built-in auto-update timer. A devbox runs agent sessions, so 8GB+ RAM is recommended.",
            "type": "info"
        }
```

- [ ] **Step 2: Validate JSON**

Run: `python3 -c "import json; json.load(open('json/happier.json')); print('ok')"`
Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add json/happier.json
git commit -m "docs(happier): document devbox/auto-update install knobs"
```

---

## Final verification (before any push/PR)

- [ ] `bash -n ct/happier.sh install/happier-install.sh` → exit 0.
- [ ] `shellcheck` on both (honoring `.vscode/.shellcheckrc`) → no new errors. (The `happier-lint` workflow runs this on the eventual PR.)
- [ ] **LXC integration matrix** from the spec (cases 1-6): real devbox install with agents on/off, PAT via env, auto-update on/off, run the Update action, and a server_only regression check. Confirm: drop-in exists at mode 600 with the expected keys; `command -v claude/codex` resolve; `<serviceName>-updater.timer` active iff auto-update on; daemon + relay both restart on update without killing a live session; server_only touches none of it. A health probe should now report `daemon_required_env` satisfied.
- [ ] Only after LXC-green: PR `feat/devbox-agents-autoupdate` → `happier-dev/main` (cross-fork from the `danljungstrom` fork), after the audit/sync PRs land.

## Spec coverage map
- Spec A (agent provisioning) → Tasks 3, 4, 5. Spec B (PAT) → Tasks 1, 4, 5. Spec C (auto-update) → Tasks 1, 2, 5. Spec D (daemon restart on update) → Task 6. Spec E (env knobs + docs) → Tasks 1, 7. Out-of-scope items (OOM, gemini/opencode) intentionally untasked.
