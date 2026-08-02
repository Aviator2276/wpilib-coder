# WPILib Sim GUI Coder Module — Living Plan

**Resume point:** all 8 phases have deliverables committed. Remaining verification items are
listed under "Next actions". Read FABLE_PROMPT.md for the original brief; this file is the
durable state.

## Phase status

| # | Phase | Status |
|---|-------|--------|
| 1 | Plan + frcmaven check | ✅ |
| 2 | Spike: simulateJava → browser via KasmVNC | ✅ works — see numbers |
| 3 | Image (`images/Dockerfile`) | ✅ built+validated arm64; sim-natives seed rebuild running; multi-arch push pending registry creds |
| 4 | Terraform module (`registry/aviator2277/modules/wpilib-sim`) | ✅ fmt/validate/6 tftest pass; run.sh executed clean in image |
| 5 | Single-app lockdown | ✅ placeholder card verified via screenshot; auth 401/200 verified; sim-covers-card retest pending image rebuild |
| 6 | Template integration (`test/template/main.tf`) | ✅ patched (API-key off LOCAL TEST ONLY, image, 3 GB, module wired); validates. Live coder-server E2E: in progress |
| 7 | Tests + CI (`.github/workflows/ci.yaml`) | ✅ tftest 6/6 local; shellcheck clean; bun tests CI-only by design |
| 8 | Docs (`README.md`) | ✅ |

## Measured facts

- Docker host: aarch64, 10 CPU, ~7.75 GiB VM.
- frcmaven.wpi.edu reachable (200); WPILib 2026.2.2; **GradleRIO plugin portal tops at 2026.2.1 — pinned**.
- Spike (3 GB / 2 vCPU cap): sim @120fps default = 191–200% CPU; **@30fps = 82% CPU, ~615 MB**.
  RSS: robot JVM ~172 MB, gradle daemon ~401 MB, wrapper ~117 MB, Xvnc ~80 MB.
- Image: 3.11 GB (base ~2.4), RO dep cache 253 MB → fresh-user offline build **9 s**.
- **simgui state lives in `<project>/simgui-window.json`** (fps key), NOT `~/.config/simgui.ini`
  (correction to FABLE_PROMPT; that path is standalone-tools only).
- `libatomic1` required for WPILib JNI (arm64 hard failure).
- KasmVNC 1.5.0: `-select-de manual -xstartup <file>` required for headless; yaml keys
  `encoding.rect_encoding_mode.{min,max}_quality`, `...clipboard.*.enabled`; unauth = 401 on every
  endpoint incl. /app → healthcheck URL embeds creds; screenshot API `/api/get_screenshot`.
- Shared-netns findings: Xvnc uses abstract sockets (@/tmp/.X11-unix/XN) → display number derived
  from per-workspace port; **no X TCP listener** (verified); robot sim binds NT on 0.0.0.0:5810/1735
  (cross-workspace exposure + first-bind-wins collision — template-level fix only).
- `build -x test` does NOT cache sim natives; `downloadDepsPreemptively` doesn't either.
  Image seed runs `simulateJavaRelease` (fails at GLFW init after downloads land) + offline
  retest guard grepping "Could not download".

## Decisions

- KasmVNC + always-on basic auth (`random_password` via `coder_env` CODER_WPILIB_SIM_PASSWORD —
  never in script body; test asserts this). User enters password once per browser session
  (username `coder`); auto-login via URL not supported by kasm 1.5 (HTTP-level auth gates everything).
- Season param `wpilib_year`: 2026 = llvmpipe GL; ≥2027 adds WPIGUI_FORCE_RENDERER=2d (untested — no
  2027 GradleRIO exists).
- X-side placeholder (feh loop, no WM) — no proxy. fps preseed loop every 60 s, never overwrites.
- JDK 17 baked; template's openjdk-25 removed in test copy (prod bug flagged in README).
- Icons: WPILib PNG via raw.githubusercontent URL for coder_app/script; `.icons/wpilib.svg`
  missing for registry frontmatter (needed only if contributed to coder/registry).

## Requests for the user

1. Verify from inside prod `OpenVPN-Client`: `curl -sI https://frcmaven.wpi.edu/artifactory/release/`
   and `https://plugins.gradle.org` → 200.
2. Container registry + org for pushing `wpilib-workspace:2026` (multi-arch buildx push).
3. Confirm registry namespace `aviator2277` (placeholder; rename dir if different).
4. Prod template needs: memory 2048→3072, image swap, drop openjdk-25 install (see README "Deploying").

## Next actions (in order)

1. Background image rebuild (sim natives seed) — on completion rerun E2E:
   container `wpilib-e2e` flow = run rendered run.sh, launch `simulateJava --offline`,
   assert window covers placeholder (screenshot), then kill sim → placeholder returns.
   Rendered script at scratchpad/run_rendered.sh; creds coder/e2etestpass123, port 16901, display :6901.
2. Local coder-server E2E (install coder CLI, `coder server`, push `test/template`, create
   workspace, click-path check). Template's entrypoint already rewrites localhost→host.docker.internal.
3. Optional: `coder templates push` of prod template once user applies README steps.
