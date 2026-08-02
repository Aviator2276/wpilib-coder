# Build a WPILib Simulation GUI module for Coder

You are building a Coder registry module that gives FRC students browser-based access to the
WPILib Simulation GUI from a Coder workspace. Plan first, then execute.

## Working directories

- `/Users/aviator2277/Nextcloud/Aviator/develop/github/wpilib` — **your output repo**. Build here.
- `/Users/aviator2277/Nextcloud/Aviator/develop/github/Custom-Coder-Templates` — production templates.
  `Java-Python-Developer/main.tf` is the integration target. **Do not edit it.** Copy it to your
  output repo as `test/template/main.tf` and modify the copy.
- `/Users/aviator2277/Nextcloud/Aviator/develop/github/registry` — the real Coder registry. Use
  `registry/coder/modules/kasmvnc/` as your structural template (main.tf, run.sh, README.md,
  main.test.ts, path_vnc.html).
- `/Users/aviator2277/Nextcloud/Aviator/develop/github/allwpilib` — WPILib source, for reference only.
  Branches `main` (2027 dev) and `origin/2026` (current season) differ in ways that matter.

Docs: https://coder.com/docs/llms.txt · https://coder.com/docs/about/contributing/modules · https://registry.coder.com/

## Goal

One button on the Coder workspace dashboard. Click it, get the WPILib Sim GUI in the browser,
interactive. If no simulation is running, the page tells the user how to start one instead of
showing a black screen. Nothing but the Sim GUI is visible — no desktop, no file manager, no
terminal. It must run acceptably in **3 GB RAM / 2-3 vCPU with no GPU**.

## Research already completed — treat as established fact, do not re-derive

These were verified by reading the source. Cited so you can confirm cheaply if needed.

### Rendering backend differs by season — this drives the whole design

| | `origin/2026` (current) | `main` (2027 dev) |
|---|---|---|
| Backend | GLFW + OpenGL3 | SDL3 + SDL_GPU (Vulkan on Linux) |
| Evidence | `wpigui/src/main/native/cpp/wpigui.cpp` includes `<GLFW/glfw3.h>`, `imgui_impl_glfw.h`; `simulation/halsim_gui/build.gradle:45` links `-lGL` for linuxarm | `wpigui.cpp:22` `<SDL3/SDL.h>`, `:36` `imgui_impl_sdlgpu3.h`; `shared/libsdlgpu.gradle` |
| Software render | Mesa llvmpipe; `LIBGL_ALWAYS_SOFTWARE=1` | `WPIGUI_FORCE_RENDERER=2d` → SDL_Renderer instead of Vulkan (`wpigui.cpp:64`, `:110-125`) |

There is **no GPU** in the target container. Software Vulkan (lavapipe) on 2 vCPU is not viable, so
the 2027 path **must** force the 2D renderer. `wpigui.cpp:398-409` already contains an automatic
`SDL_HINT_VIDEO_DRIVER=x11` fallback when Wayland is absent. Relevant env vars:
`WPIGUI_FORCE_RENDERER` (accepts `2d`/`sdl`/`renderer`/`sdlrenderer` or `3d`/`gpu`/`sdlgpu`),
`WPIGUI_SDL_GPU_DEBUG`, `LIBGL_ALWAYS_SOFTWARE`, `SDL_VIDEODRIVER`, `GALLIUM_DRIVER=llvmpipe`.

### A full WPILib install is NOT required

`./gradlew simulateJava` — what the VS Code extension's "Simulate Robot Code on Desktop" invokes —
resolves `halsim_gui` native artifacts from frcmaven.wpi.edu via GradleRIO at build time. The
WPILib installer only adds VS Code, a JDK, standalone tools (Glass, Shuffleboard, SysId, Elastic),
and an offline Maven cache. Required instead:

- **JDK 17.** `origin/2026:build.gradle:113` sets `sourceCompatibility = 17`. The existing template
  installs `openjdk-25-jdk` (`Java-Python-Developer/main.tf`, `startup_script`) — this is a latent
  bug that will likely break GradleRIO robot builds. Fix it in your copy and flag it in the README.
- `wpilibsuite.vscode-wpilib` extension — already present in the template's code-server module.
- Network reach to `frcmaven.wpi.edu` **through the OpenVPN container**. Verify this early; if the
  VPN blocks it, everything downstream fails and you need to know on day one.
- X11 + Mesa runtime libs in the image.

### Verified implementation hooks

- Sim GUI window title is exactly **`"Robot Simulation"`**, default 1280x720
  (`simulation/halsim_gui/src/main/native/cpp/main.cpp:220`; `origin/2026:...:163`).
  Use this for "is a sim running?" detection via `xdotool search --name` or `wmctrl -l`.
- Sim GUI settings persist to `$XDG_CONFIG_HOME/simgui.ini` or `~/.config/simgui.ini`
  (`wpigui.cpp:1491-1516`, `glass::SetStorageName("simgui")`). Section `[MainWindow][GLOBAL]`,
  keys `width`, `height`, `maximized`, `xpos`, `ypos`, `userScaling`, `style`, `font`, `fps`
  (`wpigui.cpp:780-815`). **Preseed this file** to pin fps=30 and the window geometry — no patching
  of WPILib required.
- `linuxarm64` halsim_gui is buildable (`simulation/halsim_gui/build.gradle:45`), so native arm64
  testing on Apple Silicon works.
- KasmVNC `vncserver` supports `-xstartup <script>`, documented as "useful to run full-screen
  applications", plus `-noxstartup` and `-select-de manual`. This is the single-app mechanism.
- KasmVNC tuning lives in `/etc/kasmvnc/kasmvnc.yaml` or `~/.vnc/kasmvnc.yaml`: `max_frame_rate`,
  jpeg `min_quality`/`max_quality`, `webp_quality`. Kasm's own benchmarks show JPEG q4 at roughly
  2.3x cheaper than q8 — on a CPU-bound box prefer JPEG at low quality over WebP.

### Decisions already made — implement these, do not relitigate

1. **KasmVNC**, not `portabledesktop`. portabledesktop only installs a binary and creates no
   `coder_app`; it targets AI agents. Do not use the stock kasmvnc module unmodified (see security).
2. **No browser-native GUI in v1.** Document it as the v2 path in the README: `halsim_ws_server`
   exposes the whole HAL over WebSocket JSON (`simulation/halsim_ws_core/doc/hardware_ws_api.md`,
   `HALSIMWS_PORT` default 3300, already serves static HTTP from a `sim/` dir) and NT4 is
   websocket-native, so an X-free browser dashboard is feasible but would lack field-view and plot
   parity. Out of scope now.
3. **Season-parameterized.** `wpilib_year` variable, default `2026`, selecting the correct render
   env vars and package set.
4. **3 GB / 2-3 vCPU budget.** Engineer to it explicitly.
5. **Prebuilt Docker image.** Ship a `Dockerfile`. Runtime install is the fallback path only.
6. **Native arm64 locally, amd64 in CI.** Image must be multi-arch.

## Security requirements — read carefully, this is the part most likely to be got wrong

**The workspace network namespace is shared.** `Java-Python-Developer/main.tf` sets
`network_mode = "container:OpenVPN-Client"`. Every workspace shares that one container's network
namespace. Therefore `127.0.0.1` is **not** private per workspace — it is shared across all
workspaces and the VPN container.

Consequences you must handle:

- The stock kasmvnc module runs `kasmvncserver -disableBasicAuth` bound to `127.0.0.1`, on the
  assumption that the netns is per-workspace. **That assumption is false here.** Without auth, any
  user in any workspace could connect to any other user's sim GUI.
- **Required:** enable KasmVNC basic auth with a per-workspace random credential generated in
  Terraform (`random_password`), passed to the agent, never logged, never written to a
  world-readable path. Also randomize the listen port the way the template already does for
  code-server via `random_integer.port`.
- Note in your README that **this same hole already exists for code-server** in the current
  template — its random port is obscurity, not authentication. Report it; do not silently fix
  unrelated production config.

**Be honest about what "locked down to one app" buys.** The user already has a full shell through
code-server's terminal. Restricting the VNC session to a single window is a UX and attack-surface
measure, **not an isolation boundary**. Do not write README claims implying it contains a hostile
user. The real boundaries are container resource limits, the netns/VPN, and the VNC credential.
State this plainly in the README's security section.

Harden anyway, cheaply: no window manager root menu (either no WM, or `matchbox-window-manager`
with menus disabled); disable clipboard and file transfer in `kasmvnc.yaml` unless a variable opts
in; do not install `xterm`, file managers, or browsers in the image; run the VNC session as the
unprivileged `coder` user.

## Architecture to build

### The core mechanism

Export `DISPLAY` in `coder_agent.env` so the code-server terminal inherits it. Then
`./gradlew simulateJava` — and the extension's "Simulate Robot Code on Desktop" button — render
onto the VNC display with **zero user configuration**. This is the keystone; validate it first.

### The "no sim running" experience

Prefer an **X-side placeholder** over an HTTP reverse proxy. A proxy in front of KasmVNC's
websocket costs CPU you do not have. Instead, the `-xstartup` script runs a supervisor loop that
keeps a fullscreen instruction card displayed at the bottom of the stacking order; when a window
titled `Robot Simulation` appears it naturally covers the card, and when the sim exits the card is
visible again. Keep the card renderer tiny (a pre-rendered PNG via `feh --fullscreen`, or similar
minimal X client) — do not pull in a toolkit stack for this.

If you determine during implementation that the X-side approach cannot give a good enough
experience, you may fall back to a gate server, but **measure the CPU cost first** and record the
justification in the plan checkpoint.

### Performance engineering (3 GB / 2-3 vCPU, no GPU)

- Preseed `~/.config/simgui.ini` with `fps=30` and 1280x720 geometry.
- `kasmvnc.yaml`: `max_frame_rate` ~24, low JPEG min/max quality, JPEG-preferred over WebP.
- 1280x720, not 1080p — matches the sim's native default, so no scaling cost.
- Memory: Gradle daemon plus robot JVM plus Xvnc plus encoder plus code-server will not fit
  comfortably. Cap Gradle (`org.gradle.jvmargs=-Xmx768m` or `--no-daemon` for sim runs) and set an
  explicit `-Xmx` for the simulated robot JVM. Bake the Gradle/Maven dependency cache into the
  **image layer** so it costs zero per-user volume space and near-zero first-build time.
- Measure and report actual RSS and CPU under an idle sim and an interactive sim. Numbers, not
  adjectives.

### Deliverables

```
wpilib/
├── registry/<namespace>/modules/wpilib-sim/
│   ├── main.tf          # variables, coder_script, coder_app, random_password
│   ├── run.sh           # install/configure/start KasmVNC + xstartup + supervisor
│   ├── xstartup.sh      # single-app session
│   ├── README.md        # registry frontmatter; NO variables table (auto-generated)
│   └── main.test.ts     # bun test
├── images/Dockerfile    # multi-arch: JDK 17, KasmVNC, Mesa, X11, fonts, gradle cache
├── test/template/       # modified copy of Java-Python-Developer for local testing
├── .github/workflows/   # terraform fmt/validate + bun test on ubuntu-latest
└── PLAN.md              # living checkpoint, see below
```

`coder_app`: single button, `display_name = "WPILib Simulator"`, sensible `order`, `share = "owner"`,
a `healthcheck` block, and support for both `subdomain = true` and path-based sharing (see how
kasmvnc's `path_vnc.html` handles the path case).

Module variables at minimum: `agent_id`, `wpilib_year`, `port`, `resolution`, `max_frame_rate`,
`jpeg_quality`, `order`, `group`, `share`, `subdomain`, `enable_clipboard`.

If you need a new **template-level** parameter or variable, do not invent it silently — record it
in `PLAN.md` under "Requests for the user" with a justification, implement against a sensible
default, and continue.

## Execution plan and interruption resilience

Usage credits may cut you off mid-run. **`PLAN.md` is your durable state.** Update it at the end of
every phase, before starting the next. It must always contain: phases with status, decisions made
and why, open questions, requests for the user, measured numbers, and the exact next action to take.
Anyone resuming should be able to read only `PLAN.md` and continue without re-reading this prompt.

Work in phases, each independently verifiable and committed:

1. **Plan.** Write `PLAN.md`. Confirm frcmaven reachability through the VPN container — this is the
   highest-risk unknown and it gates everything.
2. **Spike.** Manually, in a plain Docker container: JDK 17 + Mesa + KasmVNC + a trivial WPILib
   robot project. Get `simulateJava` rendering into a browser. Record CPU and RSS. **Do not write
   Terraform until this works** — it is the whole project's feasibility test.
3. **Image.** Multi-arch Dockerfile with the gradle cache baked in. Measure size and cold-start.
4. **Module.** Terraform + scripts, following the kasmvnc module's structure.
5. **Single-app lockdown.** xstartup, supervisor loop, placeholder card, hardening.
6. **Integration.** Wire into the template copy in `test/template/`. **Comment out the API-key
   validation block** (`data.http.api_key_validation`, `terraform_data.validate_api_key`, and the
   `data.coder_parameter.api_key` gate) so workspaces build locally — in the copy only, clearly
   marked `# LOCAL TEST ONLY — restore before prod`.
7. **Test + CI.** `bun test`, `terraform fmt`/`validate`, GitHub Actions on ubuntu-latest.
   Registry test harness needs Docker `--network=host`, which macOS lacks natively — so the bun
   tests run in CI, not locally.
8. **Docs + handoff.** README with a copy-pasteable block for adding the module to the prod
   template, the security section described above, the openjdk-25 → 17 finding, the shared-netns
   finding, and the v2 halsim_ws_server path.

You may use subagents to parallelize independent work (image build vs. Terraform authoring vs. test
harness). Give each subagent the established-facts section above so it does not re-derive them.

## Ground rules

- **Verify, don't assume.** Every performance and compatibility claim must come from something you
  actually ran. If you could not test something, say so explicitly rather than implying it works.
- Report failures with the actual output. If a phase is blocked, finish every unblocked phase and
  state precisely what you left undone and why.
- Do not modify anything in `Custom-Coder-Templates`, `registry`, or `allwpilib`. They are
  read-only references.
- Prefer boring, debuggable shell over clever abstraction. A student's mentor will be reading these
  logs at a competition with bad wifi.
- The success criterion is a single sentence: **a student opens their workspace, clicks one button,
  clicks "Simulate Robot Code on Desktop" in VS Code, and sees an interactive Sim GUI — with no
  setup, no configuration, and no other application reachable.**
