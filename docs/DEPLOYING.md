# Deploying to production

## 1. Get the image

CI builds and pushes multi-arch automatically on every push to `main` touching `images/**`
(native amd64 + arm64 runners, merged manifest): **`ghcr.io/aviator2276/wpilib-workspace:2026`**.

Make the GHCR package public once (repo → Packages → wpilib-workspace → settings → Change
visibility) so the prod Docker host can pull anonymously — or `docker login ghcr.io` on that
host. Manual fallback:

```sh
docker buildx build --platform linux/amd64,linux/arm64 \
  -t ghcr.io/aviator2276/wpilib-workspace:2026 --push images/
```

## 2. Adjust the production template

- Set the workspace container image to that tag.
- Bump the container memory limit to **4096 MB**. 2048 will OOM during builds; 3072 ran at
  85%+ with the Java language server active.
- Remove the `openjdk-25-jdk` startup install — **JDK 25 breaks GradleRIO 2026 builds**
  (WPILib pins source compatibility to 17); the image ships 17.
- Copy the memory-discipline block from the `Java-Python-Developer` template in the Custom-Coder-Templates repo's `startup_script`: it caps
  the Java language server (defaults to 1 GB per instance, and several can run) and lets the
  Gradle daemon exit after 2 idle minutes.

## 3. Add the module

Mirror of the `Java-Python-Developer` template in the Custom-Coder-Templates repo's tail:

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

## 4. Verify egress

From inside the `OpenVPN-Client` container, confirm `frcmaven.wpi.edu` and
`plugins.gradle.org` return HTTP 200 — GradleRIO needs both. (Verified reachable from the dev
machine; the VPN egress policy is the untested link.)

## 5. Subdomain vs path-based apps

The module defaults to `subdomain = true`, which requires the Coder server to have a wildcard
access URL. If your deployment doesn't (symptom: the dashboard button is greyed out with a
"subdomain applications are not configured" banner), either:

- **Easiest — pass `subdomain = false` to the module.**
  Path-based sharing needs no DNS, TLS, or server-flag changes; the module patches KasmVNC's
  web root to work under a path prefix automatically. Small caveat: path-based apps share the
  main Coder origin, which is why the module keeps its own basic auth on.
- **Or configure wildcard apps on the server** (better isolation, needed only once):
  1. DNS: wildcard record `*.coder.example.com` → the same host as your access URL.
  2. TLS: a certificate covering `*.coder.example.com` (Let's Encrypt DNS-01, or your reverse
     proxy's wildcard cert).
  3. Coder server flag/env: `CODER_WILDCARD_ACCESS_URL=*.coder.example.com` (or
     `--wildcard-access-url`), reverse proxy forwarding that wildcard host to Coder.

  Your API-key/Authentik gate on workspace *creation* is unrelated — app routing happens after
  the workspace exists and is authenticated by Coder session cookies either way.

### Site-specific: Cloudflare + Traefik at chargingcourses.com

Access URL is `labs.chargingcourses.com`; a wildcard `*.chargingcourses.com` exists and is
served by Traefik behind a 443 port-forward (no Cloudflare tunnel).

- **Subdomain apps are available.** The wildcard resolves for Coder's app-hostname format
  (`8080--main--ws--user.chargingcourses.com` verified resolving), so `subdomain = true` is
  usable once `CODER_WILDCARD_ACCESS_URL=*.chargingcourses.com` is set on the Coder server and
  Traefik routes that wildcard to it. Note the wildcard is one label deep: it covers
  `x.chargingcourses.com`, not `x.labs.chargingcourses.com`, so the wildcard access URL must
  be at the apex level, not under `labs.`.
- **The wildcard is Cloudflare-proxied** — it resolves to Cloudflare anycast, so app traffic
  runs Cloudflare -> WAN:443 -> Traefik. For sim VNC that means continuous, bandwidth-heavy
  traffic crossing the proxy, which adds latency for no benefit. Setting the wildcard record
  to DNS-only (grey cloud) points it straight at the port-forward and keeps VNC on Traefik.
  Worth doing before a class streams simultaneously.
- **Agent traffic from the VPN exit IP.** Once workspaces route through the tunnel, the agent
  reaches Coder from the VPN's exit address via Cloudflare. Cloudflare security settings (bot
  fight mode, IP reputation, security level) can challenge or block commercial VPN ranges. If
  agents stop connecting after the netns change, suspect this before suspecting the netns
  work: add a WAF allow-rule for the exit IP, or bypass Cloudflare for the agent with a hosts
  entry pointing the access-URL hostname at Traefik's LAN address plus a matching `CODER_IP`
  exception (SNI still matches, so the certificate is unaffected).

## 6. How users log in

The user opens **WPILib Simulator** on the dashboard and logs in with **their Coder username**
and the **Simulator Password they chose when creating the workspace** (a `coder_parameter`,
changeable on workspace update) — once per browser session. If they left it blank, a
per-workspace random password is used instead, readable in the workspace terminal via
`echo $CODER_WPILIB_SIM_PASSWORD`.

Wire-up in the template: pass `vnc_username = lower(data.coder_workspace_owner.me.name)` and
`vnc_password = data.coder_parameter.sim_password.value` to the module (see
the `Java-Python-Developer` template in the Custom-Coder-Templates repo for the parameter block).

## How it works under the hood

- The workspace image ships KasmVNC + Mesa (llvmpipe software GL) + JDK 17 + a read-only
  Gradle dependency cache (`GRADLE_RO_DEP_CACHE`) holding every WPILib 2026 artifact — a fresh
  user's first robot build works **offline in ~9 s**.
- The module starts KasmVNC bound to `127.0.0.1:<random port>` with **basic auth always on**,
  an X session containing only an instruction card, and no window manager.
- `DISPLAY`, `LIBGL_ALWAYS_SOFTWARE=1`, and `GALLIUM_DRIVER=llvmpipe` are exported into the
  agent environment via `coder_env`, so simulation commands render into the VNC session with
  no user configuration.
- Sim frame rate is preseeded to 30 fps per project (`simgui-window.json`); WPILib's default of
  120 fps pegs a software-rendered core.

## Security notes

- **User-chosen VNC passwords** are only as strong as the user makes them, and in the shared
  netns a weak one is guessable by sibling workspaces. The template enforces a 6-character
  minimum (KasmVNC's floor); encourage longer.
- **Shared network namespace:** the prod template runs every workspace inside the
  `OpenVPN-Client` container's netns, so `127.0.0.1` is common to all workspaces. This module
  therefore enforces basic auth on the VNC endpoint. **The same exposure exists today for
  code-server on its random port — unauthenticated.** That is prod config, deliberately not
  changed here; fixing it properly means per-workspace network namespaces.
- A running sim binds NetworkTables on `0.0.0.0:5810/1735`: reachable by sibling workspaces,
  and two simultaneous sims collide (first bind wins). Not fixable at module level.
- The single-app VNC session is attack-surface reduction, **not** an isolation boundary — the
  user already has a shell via code-server. Containment comes from container limits, the netns,
  and Coder auth.

## Measured performance (2 vCPU cap, no GPU)

| State | CPU | RAM |
|---|---|---|
| Sim idle @ 120 fps (WPILib default) | 191–200 % (pegged) | ~980 MB |
| Sim idle @ 30 fps (module preseed) | **~82 %** | **~615 MB** |
| Fresh-user first build (RO cache, offline) | — | 9 s wall |
| Full IDE session (code-server + Java LS + sim) | — | ~2.6 GB uncapped → 4 GB limit |

Biggest RAM consumers are not the sim: the Java language server (redhat.java, 1 GB default per
instance — capped to 400 MB via machine settings) and Gradle daemons (~400 MB — now exit after
2 idle minutes).

Client-attached encoder cost is not included (measured without an active browser viewer);
KasmVNC encodes only while a client is connected.

## Known gaps

- **2027/`main` season path** (`WPIGUI_FORCE_RENDERER=2d`) is wired but untested — no 2027
  GradleRIO release existed to test against.
- GradleRIO on the plugin portal was at **2026.2.1** (frcmaven at 2026.2.2) — the seed project
  pins 2026.2.1. Bump `images/seed/build.gradle` when the portal catches up.
- bun tests run in CI only (the `~test` harness requires Docker `--network=host`; macOS lacks
  it).
- v2 idea: replace VNC with a browser-native dashboard over `halsim_ws_server` (WebSocket HAL,
  port 3300) + NT4 — no X server at all. Large UI project; loses field-view/plot parity.
