#!/usr/bin/env bash
# WPILib Simulator over KasmVNC — single-application VNC session.
#
# Starts a KasmVNC server whose X session contains nothing but a placeholder
# card; when the user launches "Simulate Robot Code on Desktop" (or
# `./gradlew simulateJava`) from the code-server terminal, the sim GUI maps
# above the card. Basic auth is always on: in a shared network namespace,
# 127.0.0.1 is reachable from sibling workspaces.
set -euo pipefail

PORT="${PORT}"
DISPLAY_NUMBER="${DISPLAY_NUMBER}"
RESOLUTION="${RESOLUTION}"
SIM_FPS="${SIM_FPS}"
MAX_FRAME_RATE="${MAX_FRAME_RATE}"
JPEG_MIN="${JPEG_MIN}"
JPEG_MAX="${JPEG_MAX}"
ENABLE_CLIPBOARD="${ENABLE_CLIPBOARD}"
KASM_VERSION="${KASM_VERSION}"
VNC_USER="${VNC_USER}"
SUBDOMAIN="${SUBDOMAIN}"

PLACEHOLDER=/opt/wpilib-sim/placeholder.png

log() { printf '[wpilib-sim] %s\n' "$*"; }

# --- credential ---------------------------------------------------------------
# Injected by the module's coder_env; never templated into this script body.
# shellcheck disable=SC2157 # $${...} is terraform templatefile escaping, not $$PID
if [ -z "$${CODER_WPILIB_SIM_PASSWORD:-}" ]; then
  log "ERROR: CODER_WPILIB_SIM_PASSWORD is not set (coder_env missing?)"
  exit 1
fi

# --- install kasmvnc if the image does not already ship it --------------------
if ! command -v kasmvncserver > /dev/null 2>&1; then
  log "KasmVNC not present; installing v$${KASM_VERSION} (prefer baking it into the image instead)"
  if ! command -v sudo > /dev/null 2>&1 || ! sudo -n true 2> /dev/null; then
    log "ERROR: KasmVNC missing and no NOPASSWD sudo available to install it."
    exit 1
  fi
  # Not sourcing /etc/os-release: this runs after `set -u` and CI enforces
  # source-before-set-u ordering; a targeted grep avoids the problem entirely.
  # shellcheck disable=SC2034 # used below via $${VERSION_CODENAME} (templatefile escaping)
  VERSION_CODENAME="$(grep -oP '^VERSION_CODENAME=\K.*' /etc/os-release 2> /dev/null || true)"
  arch="$(uname -m)"
  # shellcheck disable=SC2034 # deb_arch is used below via $${deb_arch} (templatefile escaping)
  case "$arch" in
    x86_64) deb_arch=amd64 ;;
    aarch64 | arm64) deb_arch=arm64 ;;
    *)
      log "ERROR: unsupported architecture $arch"
      exit 1
      ;;
  esac
  # shellcheck disable=SC2195 # shellcheck can't see through $${} templatefile escaping
  case "$${VERSION_CODENAME:-}" in
    noble | jammy) ;;
    *)
      log "ERROR: runtime install supports Ubuntu noble/jammy only (got '$${VERSION_CODENAME:-unknown}')."
      exit 1
      ;;
  esac
  url="https://github.com/kasmtech/KasmVNC/releases/download/v$${KASM_VERSION}/kasmvncserver_$${VERSION_CODENAME}_$${KASM_VERSION}_$${deb_arch}.deb"
  curl -fsSL "$url" -o /tmp/kasmvncserver.deb
  sudo apt-get update -qq
  DEBIAN_FRONTEND=noninteractive sudo apt-get install -qq -y --no-install-recommends \
    /tmp/kasmvncserver.deb libatomic1 xdotool feh > /dev/null
  rm -f /tmp/kasmvncserver.deb
  sudo usermod -a -G ssl-cert "$USER" || true
fi

mkdir -p "$HOME/.vnc"
touch "$HOME/.Xauthority"

# --- kasmvnc configuration ----------------------------------------------------
# 127.0.0.1 only: reachable through the Coder tunnel/proxy and (unavoidably, in
# a shared netns) by sibling containers — which is exactly why auth stays on.
cat > "$HOME/.vnc/kasmvnc.yaml" << EOF
desktop:
  resolution:
    width: $${RESOLUTION%x*}
    height: $${RESOLUTION#*x}
network:
  protocol: http
  interface: 127.0.0.1
  websocket_port: $${PORT}
  ssl:
    require_ssl: false
  udp:
    public_ip: 127.0.0.1
encoding:
  max_frame_rate: $${MAX_FRAME_RATE}
  rect_encoding_mode:
    min_quality: $${JPEG_MIN}
    max_quality: $${JPEG_MAX}
data_loss_prevention:
  clipboard:
    server_to_client:
      enabled: $${ENABLE_CLIPBOARD}
    client_to_server:
      enabled: $${ENABLE_CLIPBOARD}
EOF

printf '%s\n%s\n' "$CODER_WPILIB_SIM_PASSWORD" "$CODER_WPILIB_SIM_PASSWORD" \
  | kasmvncpasswd -wo -u "$VNC_USER"

# --- single-app X session -----------------------------------------------------
# No window manager and no other clients. The placeholder loop is the entire
# session: the sim GUI, mapped later, stacks above it; when the sim exits the
# card is what remains. feh restarts if a stray keypress kills it.
cat > "$HOME/.vnc/xstartup-wpilib" << EOF
#!/bin/sh
xsetroot -solid "#12161e" 2> /dev/null || true
while :; do
  if [ -f "$PLACEHOLDER" ]; then
    feh --fullscreen --no-menus "$PLACEHOLDER" 2> /dev/null
  else
    sleep 3600
  fi
  sleep 1
done
EOF
chmod +x "$HOME/.vnc/xstartup-wpilib"

# --- path-based sharing shim (when subdomain = false) -------------------------
if [ "$SUBDOMAIN" = "false" ]; then
  http_dir=/usr/share/kasmvnc/www
  if [ -d "$http_dir" ] && sudo -n true 2> /dev/null; then
    cat << 'EOH' > /tmp/path_vnc.html
${PATH_VNC_HTML}
EOH
    sudo mv /tmp/path_vnc.html "$http_dir/path_vnc.html"
    if [ -f "$http_dir/index.html" ] && [ -L "$http_dir/vnc.html" ]; then
      sudo mv "$http_dir/index.html" "$http_dir/vnc.html"
    fi
    sudo ln -sf path_vnc.html "$http_dir/index.html"
  else
    log "WARNING: cannot patch $http_dir for path-based sharing (missing dir or sudo)."
  fi
fi

# --- start the server ---------------------------------------------------------
kasmvncserver -kill ":$${DISPLAY_NUMBER}" > /dev/null 2>&1 || true

VNC_LOG="$HOME/.vnc/wpilib-sim-start.log"
if ! kasmvncserver ":$${DISPLAY_NUMBER}" -select-de manual \
  -xstartup "$HOME/.vnc/xstartup-wpilib" > "$VNC_LOG" 2>&1; then
  log "ERROR: kasmvncserver failed to start; log follows:"
  cat "$VNC_LOG"
  exit 1
fi
log "KasmVNC up: display :$${DISPLAY_NUMBER}, http://127.0.0.1:$${PORT} (basic auth: $${VNC_USER})"

# --- sim frame-rate preseed ---------------------------------------------------
# GradleRIO sims persist GUI state to <project>/simgui-window.json and default
# to fps=120, which pegs a software-rendered CPU. Preseed fps=$${SIM_FPS} into
# any robot project that has no state yet; never touch existing files (user
# preference wins). Rescan cheaply so projects created later are covered.
preseed() {
  # shellcheck disable=SC2231 # the glob must stay unquoted; the dir var is terraform-substituted
  for d in ${PROJECTS_DIR}/*/ "$HOME"/*/; do
    [ -f "$d/.wpilib/wpilib_preferences.json" ] || continue
    [ -e "$d/simgui-window.json" ] && continue
    cat > "$d/simgui-window.json" << EOF
{
  "MainWindow": {
    "GLOBAL": {
      "fps": "$${SIM_FPS}",
      "height": "$${RESOLUTION#*x}",
      "width": "$${RESOLUTION%x*}",
      "maximized": "1"
    }
  }
}
EOF
    log "preseeded sim settings (fps=$${SIM_FPS}) into $d"
  done
}

(
  while :; do
    preseed
    sleep 60
  done
) > /dev/null 2>&1 &

log "ready"
