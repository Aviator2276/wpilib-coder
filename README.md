# WPILib Simulator for Coder

Run the WPILib Robot Simulation GUI in a browser tab from a Coder workspace. FRC teams get
the simulator without installing anything locally: one button on the Coder dashboard, no
setup, no display configuration.

## What it does

The workspace image ships JDK 17, KasmVNC, and software OpenGL, plus a baked Gradle
dependency cache so a new user's first robot build works offline in seconds.

A Terraform module starts a locked-down, password-protected VNC session containing nothing
but the simulator, and exports the display environment into the workspace. Running
`./gradlew simulateJava` — or the VS Code extension's *Simulate Robot Code on Desktop* —
renders straight into that session, and the user clicks **WPILib Simulator** on the
dashboard to see it.

## Layout

| Path | What it is |
|---|---|
| `registry/aviator2277/modules/wpilib-sim/` | The Terraform module (main.tf, run.sh, tests) |
| `images/Dockerfile` | The workspace image |
| `spike/` | The original feasibility spike, kept for reference |

## Using it

Add the module to your workspace template:

```tf
module "wpilib_sim" {
  count    = data.coder_workspace.me.start_count
  source   = "git::https://github.com/<you>/wpilib.git//registry/aviator2277/modules/wpilib-sim"
  agent_id = coder_agent.main.id
  port     = random_integer.sim_port.result
}
```

The image is built and pushed by CI to `ghcr.io/aviator2276/wpilib-workspace:2026`.

See **[docs/DEPLOYING.md](docs/DEPLOYING.md)** for the full production checklist, security
notes, measured resource usage, and known gaps.
