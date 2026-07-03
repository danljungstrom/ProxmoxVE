# LXC integration matrix — run record — 2026-07-03

Spec: docs/superpowers/specs/2026-06-27-happier-installer-devbox-updates-design.md ("Testing (LXC, before any PR)")
Branch: feat/devbox-agents-autoupdate @ 93f6609c8 (pushed to danljungstrom/ProxmoxVE for fetchability)
Host: pve-hp (192.168.0.11), fresh Debian 13.1 CTs, fully unattended installs
(mode=default + PHS_SILENT=1 + HAPPIER_PVE_* env presets — the non-interactive
install feature added on this branch made the matrix scriptable end to end).
Channel: dev (see "Upstream findings" for why not stable). Runner: /root/mx-run.sh (host).

## Results

| # | Case | CT | Result |
|---|------|----|--------|
| 1 | devbox, agents ON, no PAT | 103 happier-mxa | PASS 16/16 — claude (native installer, happier user) + codex resolve; drop-in 600 with both `*_PATH` keys, no PAT wiring; relay active + `/v1/version` answers; UI bundle installed and served |
| 2 | devbox, agents OFF, PAT via env | 104 happier-mxb | PASS — no agents; drop-in 600 with `EnvironmentFile=` only; PAT in 600 env file; **PAT absent from `systemctl show -p Environment` and unreadable by the happier user** (B1 verified live); relay active |
| 3 | auto-update ON / OFF | 103 / 104 | PASS with vendor caveat — current CLIs reject `--auto-update`; installer degrades gracefully (warn, no timer). OFF: no timer. Timer activation itself is pending a vendor CLI release with the flags |
| 4 | Update action | 103 | PASS — rc=0; relay restarted (PID 5930→7992) and healthy; daemon active after update; UI bundle same-version refresh left `current` intact (A6 fix verified); requires the json-declared 4 CPU/8192MB (2/4096 aborts by design) |
| 5 | server_only regression | 108 happier-mxc | PASS 9/9 — no agents, no node, no drop-in, no daemon unit, no timer; relay active; update helper present |
| 6 | Lint + test suite | CI-equivalent local | PASS — bash -n, shellcheck 0.11 --norc -S info, shfmt 3.13.1, 18-test suite |

Note (case 2): the relay unit carries a vendor-injected `HAPPIER_SERVER_UI_DIR=/opt/happier-dev/ui-web/current`
default on dev-channel installs; our SERVE_UI=0 contract holds (no `/var/lib/...` UI dir is wired by us).

## Fixes that came out of the matrix (committed on the branch)

1. `feat: fully non-interactive installs via env presets` — every app_questions knob preset-skippable; preset tailscale now enables TUN (latent bug).
2. `fix: CLI bootstrap env landed on the wrong side of the pipe` — env prefixed `curl`, not the consuming `bash`, so the CLI installed under /root (unreachable by the service user); resolver widened with known bootstrap layouts.
3. `fix: probe CLI support for --auto-update before passing it` — released CLIs reject unknown args; degrade with warning.
4. `fix: adapt to current CLI bootstrap and service-install behavior` — chmod 755 the /opt install dir (bootstrap creates it 700); daemon `service install` needs root; tolerate the pre-auth activation-check failure when the unit exists (current unit name: `happier-daemon.default.service`).
5. `fix: survive relay-unit reconciliation and bake update-helper pins` — reinstall the relay if the daemon service install absorbed its unit; /usr/bin/update now bakes install-time INSTALLER_REPO/REF as defaults (was silently reverting to the moving default branch).

## Upstream (vendor) findings — happier CLI, not this repo

- **Stable channel serves a broken build** (`0.2.1-preview.1775503793.4227`): `relay host install --mode system` wires the unit (ExecStart, NODE_PATH, prisma engine) into its ephemeral mktemp extract dir and never persists the server bundle; the server also crashes on missing `/var/lib/happier/migrations/sqlite`. Every fresh system-mode install on stable fails. Dev channel (`0.2.10-dev.12`) persists correctly (`/opt/happier-dev/bin`). → report to happier-dev/happier.
- `relay host install` health-check failure leaves the failed unit restart-looping (restart counter >40 observed).
- The bootstrap creates a custom `HAPPIER_INSTALL_DIR` with mode 700 (assumes its `$HOME` default).
- `--auto-update` / `--auto-update-at` not yet in released CLIs (design assumed them).

## Cleanup

Test CTs 103/104/108 destroyed after the run; /root/mx-* runner files removed from pve-hp.
