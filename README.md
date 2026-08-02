# WPILib Simulator for Coder

Browser access to the WPILib Robot Simulation GUI from a Coder workspace: one dashboard
button, a locked-down single-app VNC session, zero user configuration.

| Path | What it is |
|---|---|
| `registry/aviator2277/modules/wpilib-sim/` | The Terraform module (main.tf, run.sh, tests) |
| `images/Dockerfile` | Workspace image: JDK 17, KasmVNC, Mesa, baked Gradle dep cache |
| `test/template/main.tf` | Local-test copy of the Java-Python-Developer template |
| `spike/` | The feasibility spike (kept for reference) |
| `PLAN.md` | Development log: measured numbers, decisions, open items |
| `FABLE_PROMPT.md` | The original build brief |

## How it works

- The workspace image ships KasmVNC + Mesa (llvmpipe software GL) + JDK 17 + a read-only
  Gradle dependency cache (`GRADLE_RO_DEP_CACHE`) holding every WPILib 2026 artifact —
  a fresh user's first robot build works **offline in ~9 s**.
- The module starts KasmVNC bound to `127.0.0.1:<random port>` with **basic auth always on**
  (per-workspace `random_password`), an X session containing only an instruction card, and
  no window manager.
- `DISPLAY`, `LIBGL_ALWAYS_SOFTWARE=1`, `GALLIUM_DRIVER=llvmpipe` are exported into the agent
  environment via `coder_env`, so `./gradlew simulateJava` and the VS Code extension's
  *Simulate Robot Code on Desktop* render straight into the VNC session.
- Sim frame rate is preseeded to 30 fps per project (`simgui-window.json`); WPILib's default
  of 120 fps pegs a software-rendered core.

## Deploying to prod

1. Build and push the image (multi-arch):

   ```sh
   docker buildx build --platform linux/amd64,linux/arm64 \
     -t <registry>/wpilib-workspace:2026 --push images/
   ```

2. In the production template, set the workspace container image to that tag, bump the
   container memory limit to **3072 MB** (measured requirement; 2048 will OOM during builds),
   and remove the `openjdk-25-jdk` startup install — **JDK 25 breaks GradleRIO 2026 builds**
   (WPILib pins source compatibility to 17); the image ships 17.

3. Add the module (mirror of `test/template/main.tf`'s tail):

   ```tf
   resource "random_integer" "sim_port" {
     min = 11000
     max = 65535
   }

   module "wpilib_sim" {
     count    = data.coder_workspace.me.start_count
     source   = "git::https://github.com/<you>/wpilib.git//registry/aviator2277/modules/wpilib-sim"
     agent_id = coder_agent.main.id
     port     = random_integer.sim_port.result
     order    = 3
   }
   ```

4. Verify from inside the `OpenVPN-Client` container that `frcmaven.wpi.edu` and
   `plugins.gradle.org` return HTTP 200 — GradleRIO needs both. (Verified reachable from
   this dev machine; the VPN egress policy is the untested link.)

5. The user opens **WPILib Simulator** on the dashboard and enters username `coder` with
   the password from `$CODER_WPILIB_SIM_PASSWORD` (visible in the workspace terminal via
   `echo $CODER_WPILIB_SIM_PASSWORD`) — once per browser session.

## Security notes (read before deploying)

- **Shared network namespace:** the prod template runs every workspace inside the
  `OpenVPN-Client` container's netns, so `127.0.0.1` is common to all workspaces. This module
  therefore enforces basic auth on the VNC endpoint. **The same exposure exists today for
  code-server on its random port — unauthenticated.** That is prod config, deliberately not
  changed here; fixing it properly means per-workspace network namespaces.
- A running sim binds NetworkTables on `0.0.0.0:5810/1735`: reachable by sibling workspaces,
  and two simultaneous sims collide (first bind wins). Not fixable at module level.
- The single-app VNC session is attack-surface reduction, **not** an isolation boundary — the
  user already has a shell via code-server. Containment comes from container limits, the
  netns, and Coder auth.

## Measured performance (3 GB / 2 vCPU cap, no GPU)

| State | CPU | RAM |
|---|---|---|
| Sim idle @ 120 fps (WPILib default) | 191–200 % (pegged) | ~980 MB |
| Sim idle @ 30 fps (module preseed) | **~82 %** | **~615 MB** |
| Fresh-user first build (RO cache, offline) | — | 9 s wall |

Client-attached encoder cost is not included (measured without an active browser viewer);
KasmVNC encodes only while a client is connected.

## Known gaps

- **2027/`main` season path** (`WPIGUI_FORCE_RENDERER=2d`) is wired but untested — no 2027
  GradleRIO release existed to test against.
- GradleRIO on the plugin portal was at **2026.2.1** (frcmaven at 2026.2.2) — the seed project
  pins 2026.2.1. Bump `images/seed/build.gradle` when the portal catches up.
- bun tests run in CI only (the `~test` harness requires Docker `--network=host`; macOS lacks it).
- v2 idea: replace VNC with a browser-native dashboard over `halsim_ws_server` (WebSocket HAL,
  port 3300) + NT4 — no X server at all. Large UI project; loses field-view/plot parity.
