#!/bin/bash
# netns-leak-test.sh — verify a routed workspace leaks nothing and is isolated.
#
# Run on the Unraid HOST with at least one workspace container up. Tests 5-6
# need two. Nothing here writes config; test 4 briefly downs the tunnel and
# brings it back, so it is opt-in via --killswitch.
#
#   ./netns-leak-test.sh                          # auto-detect coder-* workspaces
#   ./netns-leak-test.sh --killswitch             # include the tunnel-drop test
#   ./netns-leak-test.sh -a coder-bob-ws1 -b coder-amy-ws1
#
# Exit 0 only if every executed test passes.

set -uo pipefail

VPN_CONTAINER="${VPN_CONTAINER:-OpenVPN-Client}"
SUBNET="${SUBNET:-172.30.0.0/24}"
TUN_IF="${TUN_IF:-tun0}"
NT_PORT="${NT_PORT:-5810}"
WS_A=""; WS_B=""; DO_KILLSWITCH=0

while [ $# -gt 0 ]; do
  case "$1" in
    -a) WS_A="$2"; shift 2 ;;
    -b) WS_B="$2"; shift 2 ;;
    --killswitch) DO_KILLSWITCH=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

pass=0; fail=0; skip=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail+1)); }
sk()   { printf '  \033[33mSKIP\033[0m  %s\n' "$*"; skip=$((skip+1)); }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

# workspace exec: short timeouts everywhere, a "leak" that hangs is still a fail
wex() { timeout 25 docker exec "$1" sh -c "$2" 2>/dev/null; }

# --- discover workspaces ------------------------------------------------------
if [ -z "$WS_A" ]; then
  mapfile -t found < <(docker ps --format '{{.Names}}' | grep '^coder-' | sort)
  WS_A="${found[0]:-}"
  [ -z "$WS_B" ] && WS_B="${found[1]:-}"
fi
[ -n "$WS_A" ] || { echo "No workspace container found (expected a running coder-* container)." >&2; exit 2; }

echo "workspace A : $WS_A"
echo "workspace B : ${WS_B:-<none — tests 5-6 will skip>}"
echo "vpn         : $VPN_CONTAINER"

# --- reference IPs ------------------------------------------------------------
hdr "0. Reference egress IPs"
HOST_IP=$(timeout 20 curl -s https://api.ipify.org || echo "")
VPN_EGRESS=$(timeout 25 docker exec "$VPN_CONTAINER" sh -c 'curl -s https://api.ipify.org' 2>/dev/null || echo "")
echo "  host (should be your ISP) : ${HOST_IP:-<unreachable>}"
echo "  vpn  (should be the VPN)  : ${VPN_EGRESS:-<unreachable>}"
if [ -n "$HOST_IP" ] && [ -n "$VPN_EGRESS" ] && [ "$HOST_IP" != "$VPN_EGRESS" ]; then
  ok "host and VPN egress differ — the tunnel itself is working"
else
  no "cannot establish distinct host/VPN egress IPs; fix the VPN before trusting anything below"
fi

# --- 1. workspace egress ------------------------------------------------------
hdr "1. Workspace egress goes out the tunnel"
WS_EGRESS=$(wex "$WS_A" 'curl -s --max-time 20 https://api.ipify.org' || echo "")
echo "  workspace egress: ${WS_EGRESS:-<unreachable>}"
if [ -z "$WS_EGRESS" ]; then
  no "workspace has no egress at all (tunnel down, or route/killswitch misconfigured)"
elif [ "$WS_EGRESS" = "$HOST_IP" ]; then
  no "LEAK: workspace egress == host ISP IP. Traffic is bypassing the VPN."
elif [ "$WS_EGRESS" = "$VPN_EGRESS" ]; then
  ok "workspace egress == VPN egress"
else
  no "workspace egress ($WS_EGRESS) matches neither host nor VPN — investigate"
fi

# --- 2. DNS ------------------------------------------------------------------
hdr "2. DNS resolves through the tunnel (no DNS leak)"
# This TXT query is answered by Google's authoritative NS with the IP of the
# *resolver* that asked — i.e. where your DNS actually egresses.
DNS_EGRESS=$(wex "$WS_A" "command -v dig >/dev/null && dig +short +time=5 +tries=1 TXT o-o.myaddr.l.google.com @ns1.google.com" | tr -d '"' | head -1)
if [ -z "$DNS_EGRESS" ]; then
  sk "dig unavailable in the workspace image (add dnsutils) — check /etc/resolv.conf manually:"
  wex "$WS_A" 'cat /etc/resolv.conf' | sed 's/^/        /'
elif [ "$DNS_EGRESS" = "$HOST_IP" ]; then
  no "DNS LEAK: queries egress from the host ISP IP ($DNS_EGRESS)"
else
  ok "DNS egresses from $DNS_EGRESS (not the host ISP IP)"
fi

# --- 3. LAN isolation ---------------------------------------------------------
hdr "3. LAN is unreachable from the workspace"
# Default route is the VPN container; only an explicit /32 for the Coder server
# should exist. Everything else RFC1918 must fail.
LAN_GW=$(ip route | awk '/^default/ {print $3; exit}')
UNRAID_IP=$(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
for target in "$LAN_GW" "$UNRAID_IP"; do
  [ -n "$target" ] || continue
  if wex "$WS_A" "curl -s --max-time 5 -o /dev/null http://$target/ || nc -z -w3 $target 22" >/dev/null; then
    no "LEAK: workspace reached LAN host $target"
  else
    ok "LAN host $target unreachable"
  fi
done

# --- 4. killswitch ------------------------------------------------------------
hdr "4. Killswitch: egress dies with the tunnel (does not fall back to LAN)"
if [ "$DO_KILLSWITCH" -ne 1 ]; then
  sk "not run (pass --killswitch to enable; briefly interrupts VPN traffic)"
else
  docker exec "$VPN_CONTAINER" ip link set "$TUN_IF" down 2>/dev/null
  sleep 3
  DOWN_EGRESS=$(wex "$WS_A" 'curl -s --max-time 10 https://api.ipify.org' || echo "")
  docker exec "$VPN_CONTAINER" ip link set "$TUN_IF" up 2>/dev/null
  if [ -z "$DOWN_EGRESS" ]; then
    ok "egress blocked while tunnel down"
  else
    no "LEAK: workspace still reached the internet as $DOWN_EGRESS with $TUN_IF down"
  fi
  echo "  NOTE: bringing $TUN_IF back up may need an OpenVPN reconnect — check the"
  echo "        container log and restart $VPN_CONTAINER if egress does not return."
fi

# --- 5. NetworkTables: both workspaces can bind 5810 --------------------------
hdr "5. NetworkTables port $NT_PORT binds in both workspaces (the original bug)"
if [ -z "$WS_B" ]; then
  sk "needs a second running workspace"
else
  # Bind via nc, falling back to python3: a stock workspace image may have neither.
  PYBIND="import socket,time;s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind((\"0.0.0.0\",$NT_PORT));s.listen(1);time.sleep(45)"
  listen() {
    wex "$1" "command -v nc >/dev/null 2>&1 && { nohup nc -l -p $NT_PORT >/dev/null 2>&1 & sleep 1; exit 0; }
              command -v python3 >/dev/null 2>&1 && { nohup python3 -c '$PYBIND' >/dev/null 2>&1 & sleep 1; exit 0; }
              exit 3"
  }
  # grep -c prints 0 AND exits non-zero on no match, so keep the fallback inside
  # the remote shell -- an outer `|| echo 0` appends a second line and breaks [ -ge ].
  bound() { wex "$1" "ss -ltn 2>/dev/null | grep -c ':$NT_PORT' || true" | tr -d '\r' | head -1; }

  listen "$WS_A"; a_rc=$?
  listen "$WS_B"; b_rc=$?
  if [ "$a_rc" = "3" ] || [ "$b_rc" = "3" ]; then
    sk "no nc or python3 in the workspace image — cannot bind a test listener."
    echo "        The image is likely stale: re-pull it on the Docker host"
    echo "        (docker pull ghcr.io/aviator2276/wpilib-workspace:2026) and retry."
  else
    a_bound=$(bound "$WS_A"); b_bound=$(bound "$WS_B")
    if [ "${a_bound:-0}" -ge 1 ] && [ "${b_bound:-0}" -ge 1 ]; then
      ok "both workspaces bound $NT_PORT simultaneously — collision fixed"
    else
      no "only one workspace could bind $NT_PORT (A=$a_bound B=$b_bound) — still sharing a netns?"
    fi
  fi
fi

# --- 6. workspaces cannot reach each other ------------------------------------
hdr "6. Workspace A cannot reach workspace B"
if [ -z "$WS_B" ]; then
  sk "needs a second running workspace"
else
  # network_mode= containers can present an empty Networks map; ask the container
  # itself as the authoritative fallback.
  B_IP=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$v.IPAddress}} {{end}}' "$WS_B" | awk '{print $1}')
  [ -n "$B_IP" ] || B_IP=$(docker inspect -f '{{.NetworkSettings.IPAddress}}' "$WS_B")
  [ -n "$B_IP" ] || B_IP=$(wex "$WS_B" "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -1")
  echo "  workspace B address: ${B_IP:-<none>}"
  if [ -z "$B_IP" ]; then
    sk "could not determine B's address"
  elif wex "$WS_A" "nc -z -w3 $B_IP $NT_PORT"; then
    no "LEAK: A reached B at $B_IP:$NT_PORT — DOCKER-USER isolation rules missing"
  else
    ok "A cannot reach B at $B_IP:$NT_PORT"
  fi
  wex "$WS_A" "pkill -f 'nc -l' || true"; wex "$WS_B" "pkill -f 'nc -l' || true"
fi

# --- 6b. VPN bypass -----------------------------------------------------------
hdr "6b. A student cannot escape the VPN by re-routing (needs NET_ADMIN in the workspace)"
BRIDGE_GW="${SUBNET%.*/*}.1"   # 172.30.0.0/24 -> 172.30.0.1
ORIG_GW=$(wex "$WS_A" "ip route | awk '/^default/{print \$3; exit}'")
if [ -z "$ORIG_GW" ]; then
  sk "could not read workspace default route"
else
  wex "$WS_A" "ip route replace default via $BRIDGE_GW" >/dev/null
  ESCAPED=$(wex "$WS_A" 'curl -s --max-time 10 https://api.ipify.org' || echo "")
  wex "$WS_A" "ip route replace default via $ORIG_GW" >/dev/null   # always restore
  if [ -n "$ESCAPED" ]; then
    no "BYPASS: workspace reached the internet as $ESCAPED via $BRIDGE_GW, off-tunnel. DOCKER-USER/WPILIB-HOST rules missing or out of order."
  else
    ok "re-routing to $BRIDGE_GW does not escape the tunnel"
  fi
fi

# --- 7. Coder connectivity ----------------------------------------------------
hdr "7. Coder agent still reachable (the exception route works)"
if wex "$WS_A" 'pgrep -f coder >/dev/null'; then
  ok "coder agent process alive in workspace"
else
  no "coder agent not running — the /32 exception route to the Coder server is likely wrong"
fi

hdr "Summary"
printf '  %d passed, %d failed, %d skipped\n\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
