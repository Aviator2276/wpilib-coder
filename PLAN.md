# WPILib Sim GUI Coder Module — Living Plan

**Resume point: Phase 2 (spike).** Read FABLE_PROMPT.md for full context; this file is the durable state.

## Phase status

| # | Phase | Status |
|---|-------|--------|
| 1 | Plan + frcmaven check | ✅ done |
| 2 | Spike: simulateJava → browser via KasmVNC in Docker | ✅ done — WORKS, see numbers |
| 3 | Multi-arch image | ⬜ |
| 4 | Terraform module | ⬜ |
| 5 | Single-app lockdown | ⬜ |
| 6 | Template integration (test copy) | ⬜ |
| 7 | Tests + CI | ⬜ |
| 8 | Docs + handoff | ⬜ |

## Measured facts

- Local Docker: aarch64, 10 CPU, ~7.75 GiB VM — can host a 3 GB-capped spike container natively (arm64).
- `frcmaven.wpi.edu` reachable from a container on this machine (HTTP 200, Artifactory 7.161.13).
  Latest WPILib release: **2026.2.2**; **GradleRIO on the plugin portal tops out at 2026.2.1** — use that.
- `plugins.gradle.org` reachable (GradleRIO plugin resolution).

### Spike results (container capped at 3 GB / 2 vCPU, arm64, 2026-08-02)

- ✅ Full pipeline works: `./gradlew simulateJava` (GradleRIO 2026.2.1, JDK 17, ubuntu 24.04) renders
  the complete Sim GUI at 1280x720 through KasmVNC 1.5.0 with basic auth (401 unauth / 200 auth).
  Screenshot verified via `GET /api/get_screenshot`.
- **CPU:** default sim fps is **120** → 191–200% CPU (pegged). With fps=30 → **82% total**, idle sim,
  no VNC client attached. Client-attached encoding cost not yet measured locally (Phase 6 item).
- **RAM:** ~615 MB total under running sim: robot JVM ~172 MB, Gradle daemon ~401 MB, wrapper ~117 MB,
  Xvnc ~80 MB. Comfortable in 3 GB alongside code-server.
- **Timing:** first `gradlew build` 18 s (warm network, cold cache); sim window up ~15 s after invoke.
- **CORRECTION to FABLE_PROMPT research:** GradleRIO-launched sims persist state to
  **`<project>/simgui-window.json`** (`MainWindow.GLOBAL.fps`, window layout), NOT `~/.config/simgui.ini`
  (that path is for standalone tools). Preseed/patch the project JSON instead. Written on sim exit;
  safe to preseed before first launch.
- `libatomic1` is required (JNI load fails without it on arm64) — in spike Dockerfile now.
- KasmVNC 1.5.0 quirks: needs `-select-de manual` + `-xstartup <script>` (else interactive DE prompt
  breaks headless start, even with `-noxstartup`); yaml keys are `encoding.rect_encoding_mode.
  {min_quality,max_quality}` and `data_loss_prevention.clipboard.{server_to_client,client_to_server}.enabled`;
  noble arm64+amd64 debs exist for 1.5.0.
- Gradle daemon runs even when invoked with `-Dorg.gradle.daemon=false` via GRADLE_OPTS/CLI in this
  setup (~400 MB). Not worth fighting at 3 GB; cap with `org.gradle.jvmargs` in image-level
  `~/.gradle/gradle.properties` instead.

## Decisions (made, with why)

- **KasmVNC** with basic auth ON + per-workspace `random_password` — shared netns makes 127.0.0.1 non-private.
- **Season-parameterized** `wpilib_year` (default 2026): 2026 = GLFW/OpenGL3 → `LIBGL_ALWAYS_SOFTWARE=1`;
  2027 = SDL3 → `WPIGUI_FORCE_RENDERER=2d`.
- **JDK 17** in image (2026 sourceCompatibility=17; template's openjdk-25 is a latent bug — fixed in test copy only).
- **X-side placeholder** (feh or similar under the sim window) instead of an HTTP gate proxy — CPU budget.
- Preseed `~/.config/simgui.ini` (`[MainWindow][GLOBAL]`, fps=30, 1280x720).
- `DISPLAY` exported via `coder_agent.env` → zero-config `simulateJava`.

## Requests for the user

1. **Verify from inside the prod OpenVPN-Client container:** `curl -sI https://frcmaven.wpi.edu/artifactory/release/` and `https://plugins.gradle.org` return 200. Local check passed but the VPN egress policy is unknown from this machine. If blocked, the module cannot work until the VPN allows these hosts (or an internal mirror is configured — GradleRIO supports maven mirrors if needed).
2. A container registry to push the multi-arch image to (ghcr.io/dockerhub org + repo name). Building locally meanwhile; template default will use a placeholder image ref you can override.

## Open questions

- None blocking. (2027/main path will be validated best-effort in the spike only if time allows; the `WPIGUI_FORCE_RENDERER=2d` env is wired regardless and documented as untested if not run.)

## Next action

Phase 2 spike: build `spike/Dockerfile` (ubuntu 24.04 + temurin-17 + kasmvnc + mesa/x11), generate a minimal
GradleRIO 2026.2.2 TimedRobot project in `spike/robot/`, run container capped at 3g/2cpu, run
`./gradlew simulateJava -PincludeDesktopSupport`, confirm "Robot Simulation" window in browser at
localhost:6900, record RSS/CPU numbers here.
