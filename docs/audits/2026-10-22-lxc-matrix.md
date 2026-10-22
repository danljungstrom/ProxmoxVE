# LXC integration matrix — run record — 2026-10-22

Purpose: validate the 2026-10 refresh before any push — upstream merge, move to the
community-scripts/core engine (pinned `8ae24cef`), Happier CLI 0.2.16 relay changes, audit
fixes, the optional features (managed codex, on-demand daemon unit, auto-update timer) and the
installer skin.
Branch: `feat/happier-refresh-2026-10` (local only, not pushed).
Host: pve-asus (192.168.0.10), fresh Debian 13.1 CTs, unattended (`mode=default` +
`PHS_SILENT=1` + `var_ctid` + storage presets + `HAPPIER_PVE_*` presets). One CT at a time,
destroyed after each; memory-guarded runs to protect the production CTs (100, 102). No
production impact.

## Harness notes

- **No push needed any more.** The core engine detects a local scripts root, so the tree is
  `scp`'d to `/root/happier-test/{ct,install,misc}` on the host and `bash ct/happier.sh` runs
  from there; `ct/happier.sh` hands `misc/happier-common.func` to the CT through the
  `HAPPIER_COMMON_FUNC` env (commit `916ed14ac`). Update tests `pct push` the same tree into the
  CT and run its `ct/happier.sh` with `PHS_SILENT=1`.
- **pve-hp unusable:** the engine refuses to create a CT there ("Thin pool pve/data … is full
  (data 95.89%)"). All runs moved to pve-asus.
- **from_source needs the default 32 GB disk.** A first attempt with `var_disk=12` (harness
  choice) died with ENOSPC; the build peaks around 22 GB used.

## Results

| # | Case | CT | Result |
|---|------|----|--------|
| 1 | devbox, installers, **stable**, agents ON, autostart ON, auto-update ON | — | **PASS** — first healthy stable relay (the CLI now lives in `/opt/happier-cli`, out of the `/opt/happier` tree the stable relay install clears). Relay active, `/v1/version` + UI 200, `happier-daemon.default.service` active with the agents drop-in, `happier-pve-update.timer` scheduled, engine `/usr/bin/update` carries the pinned core URL. |
| 1u | Update on case 1 with a planted legacy fork `/usr/bin/update` | — | **PASS** — legacy helper rewritten and migrated into the engine entrypoint. |
| 1u2 | Update on case 1 after the review fixes (`34e6f3b25`) | — | **PASS** — CLI updated via the bootstrap (not root `self update`), daemon unit re-installed (ExecStart follows the new CLI payload), stayed enabled + active, drop-in kept, `~happier/.happier` ownership intact. |
| 2 | devbox, installers, **dev**, autostart OFF | — | **PASS (fix required)** — managed `install provider codex` fails on CLI 0.2.16 ("archive exceeds expanded-byte limit"); the pinned npm fallback installed codex. Found the env drop-in's `systemctl restart` starting the daemon despite autostart OFF → `try-restart` (`f7891afec`), re-verified. |
| 3 | server_only, installers, **preview**, 2 CPU / 2 GB, + update | — | **PASS** — install and update both rc=0; update no longer aborts on the 4 CPU / 8 GB creation check, and no daemon step runs on server_only (the systemd 257 `list-unit-files` errexit fix). |
| 4b | devbox, **from_source**, stable, agents OFF, autostart ON, auto-update ON, 32 GB | 153 | **PASS** — `hstack setup-from-source` (@happier-dev/stack@0.2.16) + web UI build (~25 min), `dev.happier.stack.service` active, `/v1/version` + UI 200, "HAPPIER_PVE_AUTO_UPDATE=1 is ignored for from_source" warning shown and no timer written, drop-in skipped (nothing to wire), `RUN_EXIT=0`. |
| 5 | Skin — server_only, installers, preview, 2 CPU / 2 GB | 154 | **PASS** — Happier banner, glyph icons and indigo palette rendered on both host and container output; install rc=0 under the engine's errexit + ERR trap. Dialog theme/backtitle not exercised (unattended runs skip whiptail). |

## Not tested

- **Tailscale Serve** — needs a live tailnet / pre-auth key.
- **The auto-update timer actually firing** — it would fetch `origin/main` (the pre-refresh
  scripts) until this branch is pushed.
- **arm64** — `var_arm64=unknown`; no arm64 host.
- **Interactive dialogs** with the skin (theme + "Happier for Proxmox VE" backtitle).

## Known open item

- The engine-generated `/usr/bin/update` does not source the proxy profile (`90-http-proxy`), so
  an update behind an HTTP proxy may fail. Low priority; engine-side behaviour.

## Cleanup

CTs 153/154 (and the earlier matrix CTs) destroyed; runner, guard units, logs and staging files
removed from pve-asus and pve-hp; production CTs 100/102 untouched.
