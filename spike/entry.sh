#!/bin/bash
# Spike entrypoint: start KasmVNC on :1 with basic auth, then idle.
# The sim is launched separately via `docker exec` to mimic the
# code-server-terminal flow of the real workspace.
set -euo pipefail

VNC_USER="${VNC_USER:-coder}"
VNC_PASSWORD="${VNC_PASSWORD:-spikepassword}"
VNC_PORT="${VNC_PORT:-6901}"
VNC_GEOMETRY="${VNC_GEOMETRY:-1280x720}"

mkdir -p "$HOME/.vnc"

cat > "$HOME/.vnc/kasmvnc.yaml" << EOF
desktop:
  resolution:
    width: ${VNC_GEOMETRY%x*}
    height: ${VNC_GEOMETRY#*x}
network:
  protocol: http
  interface: 0.0.0.0
  websocket_port: ${VNC_PORT}
  ssl:
    require_ssl: false
encoding:
  max_frame_rate: 24
  rect_encoding_mode:
    min_quality: 3
    max_quality: 6
data_loss_prevention:
  clipboard:
    server_to_client:
      enabled: false
    client_to_server:
      enabled: false
EOF

# Basic auth credential (spike: fixed; module: per-workspace random_password).
printf '%s\n%s\n' "$VNC_PASSWORD" "$VNC_PASSWORD" | kasmvncpasswd -wo -u "$VNC_USER"

touch "$HOME/.Xauthority"

# Explicit single-app xstartup: no desktop environment, session stays alive
# while we launch the sim onto the display from outside.
cat > "$HOME/.vnc/xstartup.spike" << 'EOF'
#!/bin/sh
exec sleep infinity
EOF
chmod +x "$HOME/.vnc/xstartup.spike"

kasmvncserver :1 -select-de manual -xstartup "$HOME/.vnc/xstartup.spike" || {
  echo "kasmvncserver failed; log follows:"
  cat "$HOME"/.vnc/*.log || true
  exit 1
}

echo "KasmVNC up on :${VNC_PORT} (display :1)."
tail -f "$HOME"/.vnc/*.log
