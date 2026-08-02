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

## Live coder-server E2E — PASSED (2026-08-02)

Local `coder server` (brew, v2.35.3) + pushed `test/template` + workspace `sim-test`:

- Workspace Started/healthy on `wpilib-workspace:2026`; module `coder_script` ran clean.
- Xvnc `:44092 -websocketPort 54092 -interface 127.0.0.1`, DLP clipboard off, FrameRate 24,
  quality 3–6 — all module knobs present in the real process args. **No raw RFB TCP listener**
  (only 54092 listening). App healthcheck (basic-auth URL) = **healthy**.
- `coder ssh` env: `DISPLAY=:44092  LIBGL_ALWAYS_SOFTWARE=1  CODER_WPILIB_SIM_PASSWORD` set →
  `./gradlew simulateJava` with **zero exports** produced the full sim GUI (screenshot verified).
- **Two real bugs found and fixed live:**
  1. *Preseed race:* project created+simulated inside the scan interval persisted WPILib's
     fps=120 forever (never-overwrite rule). Fix: one-time 120→30 adjustment gated by a
     sentinel (`.wpilib/.sim-fps-preseeded`), skipped while a sim is on the display; 15 s scan.
     Verified: after restart file showed fps=30 + marker.
  2. *Stacking:* with no WM, map order does NOT guarantee the sim covers the placeholder —
     feh sat above the sim. Fix: raise-watcher in xstartup (xdotool windowraise every 3 s).
     Verified via X stacking order (`xwininfo -root -children`): raising feh over the sim is
     reverted by the watcher within 5 s.
- Note: kasm `/api/get_screenshot` can serve stale frames with no client attached — use
  `xwininfo` stacking for ground truth in tests, not screenshot bytes.
- `coder templates push` only uploads the template dir → module is **vendored** at
  `test/template/modules/wpilib-sim` (sync copies after edits); prod uses git/registry source.

## Image seed — RESOLVED (2026-08-02)

The "wedged build" root cause: executing `simulateJavaRelease` in a Docker RUN launches a
headless robot JVM that never exits; `timeout` kills only the gradlew client, the daemon +
robot JVM survive, and the next gradle invocation blocks on the busy daemon forever.
Fix: `simulateJavaRelease --dry-run` resolves all sim natives at configuration time with no
execution (verified: 890 MB incl. halsim_gui downloaded in 11 s), and
`--offline --dry-run` is the guard. **Build now takes 96 s.** Final image: 1.1 GB RO cache,
`build` and `simulateJavaRelease` both pass fully offline in a fresh container.
Workspace `sim-test` restarted onto the final image: healthy, DISPLAY set, halsim in cache.

## Stale-extension bug — FIXED (2026-08-02, reported by user)

User's "new WPILib example project" failed with Groovy `InvokerHelper` NoClassDefFoundError.
Root cause (Opus subagent diagnosis): code-server installs `wpilibsuite.vscode-wpilib` from
Open VSX, where WPILib's LAST published version is **2021.3.1** — it generates 2021 projects
(Gradle 6.0.1) that cannot run on JDK 17 (Groovy 2.5 vs JDK-16+ encapsulation). Not metaspace,
not the RO cache. Current versions ship only as GitHub-release VSIXs.
Fix: extension removed from the code-server module's list; image bakes
`vscode-wpilib-2026.2.1.vsix` at /opt/wpilib-sim/; module run.sh installs it once code-server
is up (replacing any stale version). The user's old `SimpleSim` project is a 2021 project and
must be recreated with the fixed extension — not migrated.
Also (separate hardening): gradle.properties now adds `-XX:MaxMetaspaceSize=384m`.
VNC login is now workspace-owner username + user-set "Simulator Password" parameter
(min 6 chars, blank = random fallback); verified live admin/frcrocks=200, others 401.
Git history rewritten: >100 MB blobs (spike build artifacts, .terraform providers) purged,
co-author trailers removed; user must `git push --force -u origin main`.

## Remaining user items

1. Registry namespace confirmation (`aviator2277` placeholder; rename dir if different).
2. Multi-arch image push: `docker buildx build --platform linux/amd64,linux/arm64 -t <reg>/wpilib-workspace:2026 --push images/`
3. Prod VPN egress check (frcmaven + plugins.gradle.org from OpenVPN-Client container).
4. Local test env is left RUNNING for hands-on trial: coder server http://localhost:3000
   (admin@example.com / LocalTest#2026), workspace `sim-test`. Teardown:
   `coder delete sim-test --yes && pkill -f "coder server"`.
