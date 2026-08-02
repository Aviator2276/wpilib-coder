---
display_name: WPILib Simulator
description: Browser access to the WPILib Robot Simulation GUI over a locked-down single-app KasmVNC session
icon: ../../../../.icons/wpilib.svg
verified: false
tags: [vnc, wpilib, frc, simulation]
---

# WPILib Simulator

Adds one dashboard button that opens the [WPILib Robot Simulation GUI](https://docs.wpilib.org/en/stable/docs/software/wpilib-tools/robot-simulation/simulation-gui.html) in the browser. The VNC session contains nothing but the sim: no desktop, no window manager, no terminal. When no simulation is running, the user sees an instruction card telling them to start one from VS Code; the sim window covers the card automatically when it starts.

```tf
module "wpilib_sim" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/aviator2277/wpilib-sim/coder"
  version  = "1.0.0"
  agent_id = coder_agent.main.id
  port     = random_integer.sim_port.result
}

resource "random_integer" "sim_port" {
  min = 11000
  max = 65535
}
```

The module exports `DISPLAY` (and the season-appropriate software-rendering variables) into the agent environment, so `./gradlew simulateJava` — and the WPILib VS Code extension's **Simulate Robot Code on Desktop** — render into the VNC session with zero user configuration.

## Requirements

- Linux workspace, Ubuntu noble or jammy if KasmVNC must be runtime-installed. Prefer an image with KasmVNC, JDK 17, Mesa, and `libatomic1` preinstalled (see this repo's `images/Dockerfile`) — runtime install adds minutes to every start.
- JDK 17 for WPILib 2026 robot builds.
- Reachability to `frcmaven.wpi.edu` and `plugins.gradle.org` for GradleRIO dependency resolution.
- ~1 GB RAM and most of one core for an idle sim at 30 fps (measured: ~82% of one core, ~615 MB RSS including Gradle). Budget 3 GB total alongside code-server.

## Sizing and tuning

The sim's own frame rate is preseeded to 30 fps into each robot project's `simgui-window.json` (WPILib's default of 120 fps pegs a software-rendered CPU). Existing files are never overwritten — user preferences win. Use `sim_fps`, `max_frame_rate`, `jpeg_quality_min`/`jpeg_quality_max`, and `resolution` to trade quality against CPU.

## Season support

`wpilib_year = "2026"` (default) targets the GLFW/OpenGL3 sim GUI via Mesa llvmpipe. `"2027"` additionally sets `WPIGUI_FORCE_RENDERER=2d` for the SDL3-based GUI, whose default Vulkan path is not viable in software.

> [!NOTE]
> The 2027 path is wired but was **not exercised end-to-end** during development (no 2027 GradleRIO release existed to test against). The 2026 path is fully verified.

## Security

Read this section before deploying.

- **Basic auth is always on.** This module is built for deployments where workspaces share a network namespace (`network_mode = "container:..."`), where `127.0.0.1` is reachable from every sibling workspace. A random port alone would be obscurity, not authentication. Pass `vnc_username` (e.g. the workspace owner's name) and `vnc_password` (e.g. from a masked `coder_parameter` so the user picks it, minimum 6 characters); with no `vnc_password`, a per-workspace random credential is generated, readable via `$CODER_WPILIB_SIM_PASSWORD`. Credentials are entered once per browser session. A user-chosen password is only as strong as the user makes it — encourage 12+ characters.
- **The single-app session is attack-surface reduction, not an isolation boundary.** The same user already has a full shell in the code-server terminal. What contains the user is the container's resource limits, its network namespace, and Coder's own authentication — not the absence of apps inside the VNC session.
- **Known shared-netns limitations this module cannot fix:** a running robot sim binds NetworkTables on `0.0.0.0:5810`/`1735`, so sibling workspaces can reach any user's NT server unauthenticated, and two simultaneous sims collide on those ports (first bind wins). Fixing this requires per-workspace network namespaces at the template level.
- Clipboard transfer between browser and session is disabled unless `enable_clipboard = true`.
- X display numbers are derived from the per-workspace port because X abstract sockets live in the (shared) network namespace; cross-workspace X connections are refused without the per-user xauth cookie.

## Simulating a robot

1. Open the workspace's VS Code, open a robot project.
2. `Ctrl+Shift+P` → **WPILib: Simulate Robot Code** (or run `./gradlew simulateJava` in the terminal).
3. Click **WPILib Simulator** on the workspace dashboard. The sim appears within ~15 seconds of launch; until then the instruction card is shown.

## Future: X-free browser dashboard

WPILib ships `halsim_ws_server`, which exposes the entire HAL over WebSocket JSON (port 3300) — and NetworkTables 4 is WebSocket-native. A future version could replace VNC entirely with a purpose-built web dashboard (no X server, dramatically less CPU), at the cost of losing field-view/plot parity with the native GUI. Out of scope for v1.
