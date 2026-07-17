# Design — Happier installer: functional devbox + hands-off updates

Date: 2026-06-27 · Status: approved (brainstorming) · Target branch: new feature branch off `daemon-auth` (the audit/sync work)

## Context

The Proxmox helper script (`ct/happier.sh` + `install/happier-install.sh`) installs Happier — an E2E-encrypted platform for running and remotely controlling AI coding-agent sessions (Claude Code / Codex / Gemini / OpenCode). The `devbox` install type provisions the **server-light + daemon**; the daemon is what actually runs agent sessions.

Two gaps were found by researching the docs (docs.happier.dev), the `@happier-dev/stack` CLI, and — decisively — the live happier-dev infrastructure:

1. **The devbox daemon ships non-functional.** The daemon requires `HAPPIER_CLAUDE_PATH`, `HAPPIER_CODEX_PATH`, and (for git work) `GITHUB_PERSONAL_ACCESS_TOKEN`, plus the `claude`/`codex` binaries. The installer sets none of these (`grep` over `install/happier-install.sh` returns zero references). The live infra confirms it: a health probe reports `daemon_required_env_present: false`, `daemon_missing_env: [GITHUB_PERSONAL_ACCESS_TOKEN, HAPPIER_CLAUDE_PATH, HAPPIER_CODEX_PATH]` — these are applied **post-install** via an out-of-band drop-in. A fresh devbox can't run agents until the operator manually repeats that work.

2. **Updates are manual and leave the daemon stale.** The managed runtime supports a built-in **auto-update timer** (`--auto-update`) that is minisign-verified, atomic, health-checked, and auto-rolls-back — the installer never enables it. And `ct/happier.sh:update_script` restarts the *relay* unit but not the *daemon* unit, so after a CLI self-update the running daemon keeps the old CLI (the live doctor reports exactly this: `runningDaemonMismatch → happier daemon restart`).

Outcome: a devbox that works out of the box (agents wired, optionally installed) and updates that are hands-off and leave nothing stale.

## Scope

In scope (all **devbox-focused**, all back-compatible — new behavior is opt-in or additive):
- `install/happier-install.sh`: agent provisioning, daemon env drop-in, daemon PAT, auto-update enablement.
- `ct/happier.sh:update_script`: restart the daemon on the devbox update path.
- `json/happier.json`: document the new env knobs.

Out of scope:
- `server_only` and `from_source` install paths (unchanged).
- The framework patches (`build.func`/`core.func`/`install.func`) and `happier-common.func`.
- Daemon OOM/memory limits — the daemon systemd unit is CLI-managed; we cannot cleanly inject `MemoryMax`. Add only a brief RAM note in the json/docs.
- Gemini / OpenCode agents — the daemon env contract here only keys `claude` + `codex`; revisit if/when those gain documented daemon-env keys.

## Components

### A. Devbox agent provisioning

Runs only when `INSTALL_TYPE == devbox`, after the daemon background service is installed. Three steps, in order:

1. **Optional agent install.** Toggle: whiptail "Install claude + codex now?" (default **yes**) in `ct/happier.sh:app_questions`; non-interactive via `HAPPIER_PVE_INSTALL_AGENTS=1|0` (default `1`). When enabled, install the agent CLIs globally via npm (Node 24 is already present on the devbox path): `@anthropic-ai/claude-code` (provides `claude`) and `@openai/codex` (provides `codex`). Each install is **non-fatal** — on failure, `msg_warn` and continue (the daemon can still be wired to a later manual install).
2. **Path detection (always).** Resolve `claude_path="$(command -v claude || true)"` and `codex_path="$(command -v codex || true)"` after any install.
3. **Daemon env drop-in (always).** Write a systemd drop-in for the devbox daemon unit containing only the keys that resolved:
   - `HAPPIER_CLAUDE_PATH=<claude_path>` (if non-empty)
   - `HAPPIER_CODEX_PATH=<codex_path>` (if non-empty)
   - `GITHUB_PERSONAL_ACCESS_TOKEN=<pat>` (see B, if provided)
   Drop-in is written via `printf` (never heredoc), owned appropriately, `chmod 600`. Then `systemctl daemon-reload` and restart the daemon unit (best-effort; non-fatal).

Daemon unit name: resolve during implementation from how the devbox background service is installed (`install_devbox_background_service`). The live units are `happier-daemon*.service`; the drop-in dir is `/etc/systemd/system/<unit>.d/` (system mode) or the user-unit equivalent. If the unit cannot be resolved, skip the drop-in with a clear `msg_warn` rather than guessing.

### B. Daemon PAT

`GITHUB_PERSONAL_ACCESS_TOKEN` is **optional**. Source order: `HAPPIER_PVE_GITHUB_PAT` env var, else — only on devbox **and** an interactive TTY — a whiptail **password** box ("GitHub PAT for the daemon's git operations (optional, Enter to skip)"). If a value is obtained, include it in the drop-in (component A.3); otherwise omit the key entirely. The token is never echoed to the screen or logs; it lives only in the `chmod 600` drop-in. Mirror the existing careful token handling in the script (the release-fetch `happier_github_curl` pattern).

This is a distinct secret from the script's existing `HAPPIER_GITHUB_TOKEN` (which authenticates release-asset fetches); do not conflate them.

### C. Auto-update timer

Installers/devbox path only (the managed relay runtime). Toggle: whiptail "Enable automatic updates?" (default **OFF**) in `app_questions`; non-interactive via `HAPPIER_PVE_AUTO_UPDATE=1|0` (default `0`), with `HAPPIER_PVE_AUTO_UPDATE_AT` (default `04:00`, validated `HH:MM`). When enabled, append `--auto-update --auto-update-at=<HH:MM>` to the existing `happier relay host install` invocation in `install_managed_relay_runtime`. No new systemd authoring on our side — the CLI installs and reconciles its own `<serviceName>-updater` timer. When disabled, omit the flags (no timer installed; default behavior preserved).

### D. Daemon restart on update

`ct/happier.sh:update_script`, the managed/installers branch: after the existing `self update` + `relay host install` + relay-unit restart, additionally restart the daemon when a devbox daemon is present — prefer `"${cli_bin}" daemon restart` (best-effort, `|| true`); fall back to restarting the daemon systemd unit if the CLI verb is unavailable. Gate on daemon presence (detect via the devbox daemon systemd unit existing, or a successful `"${cli_bin}" daemon status`) so server-only updates are unaffected. Safe under the daemon's `KillMode=process` — in-flight agent sessions survive a daemon restart.

### E. New env knobs (all optional, documented)

| Var | Default | Effect |
|-----|---------|--------|
| `HAPPIER_PVE_INSTALL_AGENTS` | `1` | Install claude + codex on devbox |
| `HAPPIER_PVE_GITHUB_PAT` | (unset) | Daemon `GITHUB_PERSONAL_ACCESS_TOKEN` |
| `HAPPIER_PVE_AUTO_UPDATE` | `0` | Enable the managed auto-update timer |
| `HAPPIER_PVE_AUTO_UPDATE_AT` | `04:00` | Auto-update time (HH:MM) |

Add one `json/happier.json` `notes` entry summarizing these + the brief devbox-RAM note.

## Data flow

Install (devbox): `app_questions` (collect toggles) → CT create → `install/happier-install.sh` → managed relay install (with `--auto-update` flags if enabled) → daemon background service install → **[new]** optional agent install → path detect → write daemon env drop-in (claude/codex paths + optional PAT, chmod 600) → daemon-reload + restart → existing daemon-auth/next-steps.

Update (devbox): `update_script` → UI bundle refresh → `self update` → `relay host install` → restart relay unit → **[new]** restart daemon.

## Error handling

- Agent install failure → `msg_warn`, continue (env drop-in still written for whatever resolved; user can install later and re-run).
- Daemon unit unresolved → skip drop-in with `msg_warn` (don't write to a guessed path).
- PAT absent → omit the key (not an error).
- Invalid `HAPPIER_PVE_AUTO_UPDATE_AT` → `msg_warn` + fall back to `04:00` (or disable the flag) rather than passing a bad value to the CLI.
- All new daemon-restart / drop-in steps are best-effort and must not abort the install/update under the ERR trap (guard with `|| true` / explicit checks, matching the script's existing failure-path conventions).

## Testing (LXC, before any PR)

1. Devbox install, agents toggle ON, no PAT → after install: `command -v claude` and `command -v codex` resolve; the daemon drop-in exists with both `*_PATH` keys, `chmod 600`, no PAT key; daemon active; a health probe shows `daemon_required_env` for the two paths satisfied.
2. Devbox install, agents OFF, `HAPPIER_PVE_GITHUB_PAT` set via env → drop-in has the PAT key (mode 600) and whatever paths pre-existed; no agents installed.
3. Auto-update ON → the CLI's `<serviceName>-updater.timer` is active (`systemctl is-active`); OFF → no updater timer.
4. Run the helper-script Update action on a devbox → relay unit and daemon both restart; an in-flight session is not killed.
5. `server_only` install → none of the new steps run (regression check).
6. `bash -n` on changed files; the `happier-lint` workflow passes.

## Rollout

New feature branch off `daemon-auth`. Commit grouped by component (agent-provisioning+drop-in, PAT, auto-update, update-daemon-restart, docs) via `/commit`. LXC-test, then PR to `happier-dev/main` after the audit/sync PRs land. No push/PR until LXC-green.

## Deviations (as implemented, 2026-07-01)

Recorded post-implementation on `feat/devbox-agents-autoupdate`; the sections above are kept
as approved for history.

- **A.1 premise wrong — Node is NOT pre-present on the installers devbox path.** The managed
  installer ships a prebuilt CLI binary without Node; only the from_source path brings Node.
  `install_devbox_agents` therefore installs Node 24 on demand when npm is missing
  (`install/happier-install.sh`, guarded non-fatal), instead of assuming it exists.
- **Out-of-scope list overtaken by events.** The from_source devbox path also received the
  agent provisioning + daemon env drop-in (same helpers, second call site), and
  `misc/happier-common.func` + `.github/workflows/happier-lint.yml` received lint-driven
  touch-ups during review.
- **PAT storage hardened beyond the spec.** The daemon PAT is written to a root-owned 600
  `EnvironmentFile=` referenced from the drop-in, not an `Environment=` directive (unit
  Environment values are readable by unprivileged users via D-Bus). The PAT is validated
  against `^[A-Za-z0-9_]+$` before writing.
- **claude install method changed from npm to the native installer.** Anthropic's docs
  recommend the native installer and warn against root npm globals (which would also break
  claude's self-update for the happier user). claude now installs via
  `curl -fsSL https://claude.ai/install.sh | bash` as the happier user (lands in
  `~happier/.local/bin/claude`; the daemon drop-in resolves that path). codex stays on the
  vendor-documented npm global install; Node 24 is installed on demand for it.
- **Tailscale pre-auth key no longer passed on argv.** `tailscale up --auth-key=file:<600
  temp file>` instead of `--authkey=<key>`, so the key is not readable in /proc/*/cmdline
  during the enrollment window.

## Deviations (matrix hardening, 2026-07-02/03)

Found and fixed during the unattended LXC matrix run (see `docs/audits/2026-07-03-lxc-matrix.md`);
the current vendor CLI / service behavior differed from what the 2026-07-01 implementation assumed.

- **`--auto-update` capability probe before use.** Released CLIs may not know the auto-update
  flags yet (`relay host install` rejects unknown arguments), so `install_managed_relay_runtime`
  probes `relay host install --help` and only passes `--auto-update --auto-update-at` when the flag
  is advertised, warning and continuing (with the timer disabled) otherwise instead of failing the
  install. (The 2026-07-16 audit later hardened this probe against a pipefail/SIGPIPE false negative.)
- **Update-helper pins baked at install time.** `write_update_helper` bakes the install-time
  `INSTALLER_REPO`/`INSTALLER_REF` as the generated `/usr/bin/update` DEFAULTS (env still overrides
  at update time), so a pinned install updates from the same ref instead of silently jumping to
  `main`.
- **Relay-unit reconciliation reinstall.** The daemon `service install --mode system` was observed
  to remove/absorb the relay unit during reconciliation on fresh installs, so
  `ensure_relay_host_installed` reinstalls the relay with the exact captured argument set when the
  unit vanished. (The 2026-07-16 audit added a post-check that hard-fails if the unit is still
  missing after the recovery reinstall.)
