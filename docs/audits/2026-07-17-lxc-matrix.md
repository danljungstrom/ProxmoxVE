# LXC integration matrix — run record — 2026-07-17

Purpose: validate the 2026-07-16 audit remediation's LXC-gated findings before push
(A3, D1, D2, G1, P2) and regression-check the session's update-path/tailscale changes.
Branch: `feat/devbox-agents-autoupdate` (pushed to `danljungstrom/ProxmoxVE` for fetchability).
Host: pve-hp (192.168.0.11), PVE 9.1.1, fresh Debian 13.1 CTs, unattended
(`mode=default` + `PHS_SILENT=1` + `var_ctid` + `var_template_storage`/`var_container_storage`
+ `HAPPIER_PVE_*` presets). Channel: dev for installs (stable is broken — see G1). One CT at a
time, destroyed after each; host was memory-pressured (swap full, ~5–6 GB available) so every run
was memory-guarded with a hard abort + auto-destroy below 2 GB available to protect the live
production CTs (105 rust-server, 106 code, 107 happier, 202 happier-dev). No production impact.

## Harness notes (this host)

- **GitHub-raw rate-limiting** from repeated attempts made ct/happier.sh's bootstrap fetch hang.
  `fetch_remote_script` (ct/happier.sh:18) uses a bare `curl -fsSL` with **no `--max-time`/
  `--connect-timeout`**, so a throttled/stalled connection hangs the install indefinitely with no
  output. Latent robustness gap (same class as the A9 hardening) — noted, not fixed this session.
  Worked around by staging the fork files on the host and sourcing build.func/happier-common.func
  from local copies.
- Default-mode build.func still prompts for **storage pool** when the host has several — preset
  `var_template_storage=local` / `var_container_storage=local-lvm`. The daemon **PAT** prompt is
  only skipped when `HAPPIER_PVE_GITHUB_PAT` is set (even to empty). Headless runs need **`HOME`**
  exported (systemd-run has none; `setup_nodejs` reads `$HOME` under `set -u`) — a harness artifact,
  not a code bug (real installs run from a root shell).

## Results

| # | Case | CT | Result |
|---|------|----|--------|
| 1 | devbox, installers, dev, agents OFF, autostart ON, serve UI | 103 | **PASS** — install rc=0, relay `happier-server-dev` active, UI bundle served (http://…:3005), "Completed successfully". Live-verified: **E1** (`/usr/bin/update` sources `90-http-proxy`), **A9** (helper downloads to a temp file with `--max-time`, no `curl\|bash`), **B1** (no `HAPPIER_PVE_*`/PAT in the relay unit env), baked update-helper pins. |
| 2 | Update action (on case 1) | 103 | **PASS (fix required)** — **A3** confirmed REAL: the bare `relay host install` reinstall rewrote `HAPPIER_SERVER_UI_DIR` from the managed `/var/lib/happier-dev/ui-web/current` to the vendor default `/opt/...`. Implemented the re-pass fix; re-test: update rc=0, UI_DIR restored to `/var/lib/...`, relay active. Also live-validated **A1** (guarded reinstall, no abort), **A2** (relay stayed active/enabled), **D2** (dev channel detected, CLI self-update, UI refresh), **A6** (same-version UI refresh, no debris). The re-test also caught two errexit bugs in the first fix attempt (shellcheck missed both). |
| 3 | G1 — stable channel probe | 104 | **FAIL (expected) — stable STILL broken.** Fresh stable install: CLI + UI install, then `relay host install` aborts with "relay runtime did not become healthy (http://127.0.0.1:3005/v1/version)", install exit 1 — matches the 2026-07-03 finding. Drove the G1 fix (drop the "recommended" label + warn). Vendor-side (happier CLI), not this repo. |
| 4 | D1 — from_source path | 103 | **PARTIAL — path exercised, no code defect.** Node 24 installed, `hstack setup-from-source` (@happier-dev/stack@0.2.0) built for ~12 min with no code errors, then the stack build's memory peak crossed the 2 GB guard on this loaded host → auto-aborted to protect production. The `HOME: unbound variable` seen first was the systemd-run harness (no `HOME`), fixed with `HOME=/root`. Full-build completion is memory-blocked on *this* host, not a code issue. A permanent from_source CI/matrix case is still to add. |
| P2 | Tailscale Serve loop | — | **Not tested** — needs a live tailnet / pre-auth key; deferred. |

## Verdicts feeding the backlog

- **A3 → done** (fixed + LXC-verified end-to-end).
- **G1 → done** (re-verified still broken → label/warn fix).
- **D2 → partial** (update path validated live; channel-detection unit tests + the `-updater.timer`
  name E2E remain — the timer leg is vendor-blocked because the released CLI still rejects
  `--auto-update`).
- **D1 → partial** (path exercised, no defect; completion memory-blocked; permanent case to add).
- **P2 → open** (needs a tailnet).
- Regression: A1/A2/A4/A5/A6/E1/A9/B1 all live-verified green on the dev-channel install + update.

## Cleanup

All matrix CTs (103/104) destroyed; host runner/log/staging files removed; production CTs
(105/106/107/202) untouched and running; available memory restored to ~5.7 GB.

## HEAD re-smoke (2026-07-20)

Re-ran a dev-channel devbox install + update on the current branch HEAD (`04aa8b015` — includes the
post-matrix test/refactor/Codex-fix commits the 07-17 run predated) to close that gap. Host had
~13 GB free. **Install rc=0** (relay active, UI served, "Completed successfully"). **Update rc=0**
with two edge cases driven live: **A3** — `HAPPIER_SERVER_UI_DIR` restored to `/var/lib/...` after
being reset to `/opt/...`; and the **Codex A2 fix** — a relay left `enabled` but manually stopped
(`systemctl stop`) before the update stayed `enabled` + `inactive` afterward (the old code would
have turned it back on). Confirms the D2 `detect_installed_channel` refactor, the A2 restore rework,
and A3 all work on HEAD. CT destroyed, staging removed, production untouched.
