#!/bin/bash
# vpn-gateway-ensure.sh — turn the OpenVPN-Client container into a routing gateway
# for a dedicated per-workspace Docker network, with a fail-closed killswitch.
#
# Run this on the Unraid HOST (not inside a container), from the User Scripts
# plugin: once at "At Startup of Array", and again on a schedule (*/5 * * * *).
# Every action is idempotent and self-healing — Unraid recreates containers on
# every "Apply" in the Docker tab, which silently drops network attachments and
# in-container iptables rules. Re-running restores them.
#
# It does NOT set net.ipv4.ip_forward: /proc/sys is mounted read-only inside
# Docker containers, so that must come from the container's create-time
# --sysctl flag (see docs/UNRAID-PER-WORKSPACE-NETNS.md step 2).

set -euo pipefail

# --- config -------------------------------------------------------------------
VPN_CONTAINER="${VPN_CONTAINER:-OpenVPN-Client}"
NET_NAME="${NET_NAME:-wpilib-net}"
SUBNET="${SUBNET:-172.30.0.0/24}"
VPN_IP="${VPN_IP:-172.30.0.2}"
TUN_IF="${TUN_IF:-tun0}"

log() { printf '[vpn-gateway] %s\n' "$*"; }
die() { printf '[vpn-gateway] ERROR: %s\n' "$*" >&2; exit 1; }

# in-container iptables
dex() { docker exec "$VPN_CONTAINER" "$@"; }

# --- 0. preflight -------------------------------------------------------------
docker inspect "$VPN_CONTAINER" >/dev/null 2>&1 \
  || die "container '$VPN_CONTAINER' not found"

[ "$(docker inspect -f '{{.State.Running}}' "$VPN_CONTAINER")" = "true" ] \
  || die "container '$VPN_CONTAINER' is not running"

dex sh -c 'command -v iptables' >/dev/null 2>&1 \
  || die "iptables not present inside '$VPN_CONTAINER' — install it in that image first"

# Present is not the same as usable: without NET_ADMIN every rule below fails with
# a "Permission denied (you must be root)" that reads like a container-user problem.
dex iptables -L -n >/dev/null 2>&1 \
  || die "iptables is present in '$VPN_CONTAINER' but cannot run (missing NET_ADMIN?).
       Add '--cap-add NET_ADMIN' to that container's Extra Parameters in the Unraid
       Docker tab and Apply, then re-run. See step 2 of the runbook."

# --- 1. the workspace network -------------------------------------------------
# icc stays ON: workspaces must be able to reach the gateway container. Isolation
# between workspaces is enforced in DOCKER-USER at step 4 instead, which is
# narrower than Docker's all-or-nothing icc=false.
# enable_ip_masquerade=false is load-bearing, not tidiness. Docker NATs every
# user-defined network by default, so a student holding NET_ADMIN can point their
# default route at the bridge and reach the internet straight off the host uplink,
# tunnel bypassed. Verified escaping in local testing. With NAT off, those packets
# leave with an unroutable 172.x source and die; the only working path out is the
# gateway, which does its own MASQUERADE on tun0.
MASQ_OPT="com.docker.network.bridge.enable_ip_masquerade"
if ! docker network inspect "$NET_NAME" >/dev/null 2>&1; then
  log "creating network $NET_NAME ($SUBNET, ip_masquerade off)"
  docker network create --subnet "$SUBNET" --opt "$MASQ_OPT=false" "$NET_NAME" >/dev/null
else
  have=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NET_NAME")
  [ "$have" = "$SUBNET" ] || die "network $NET_NAME exists with subnet $have, expected $SUBNET"
  masq=$(docker network inspect -f "{{index .Options \"$MASQ_OPT\"}}" "$NET_NAME")
  if [ "$masq" != "false" ]; then
    # `network rm` refuses while any endpoint remains, so list them explicitly --
    # the VPN container itself is usually the one holding it open.
    eps=$(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$NET_NAME")
    die "network $NET_NAME was created with IP masquerading ON, which lets a workspace bypass the VPN.
       It must be recreated. Attached now: ${eps:-<none>}
         1. stop any workspaces on it (Coder: stop the workspace)
         2. docker network disconnect $NET_NAME $VPN_CONTAINER
         3. docker network rm $NET_NAME
         4. ALLOW_VPN_RESTART=1 CODER_IP=\$CODER_IP $0
       Step 3 fails with 'has active endpoints' if anything is still attached; disconnect
       each name listed above first. Step 4 recreates the network correctly and re-attaches."
  fi
fi

# --- 2. attach the VPN container ----------------------------------------------
# OpenVPN's `redirect-gateway def1` installs 0.0.0.0/1 and 128.0.0.0/1 to override
# the default route without replacing it. Between them they cover all of IPv4, so
# Docker refuses to program *any* address into the live sandbox:
#   "cannot program address ... conflicts with existing route {Dst: 128.0.0.0/1}"
# No choice of subnet avoids this -- every RFC1918 range sits under one half or
# the other. Attaching while the container is stopped sidesteps it entirely: the
# endpoint is recorded and applied at start, before OpenVPN installs any routes.
attach() {
  if docker network connect --ip "$VPN_IP" "$NET_NAME" "$VPN_CONTAINER" 2>/tmp/wpilib-attach.err; then
    return 0
  fi
  grep -q "conflicts with existing route" /tmp/wpilib-attach.err || {
    cat /tmp/wpilib-attach.err >&2; return 1; }

  if [ "${ALLOW_VPN_RESTART:-0}" = "1" ]; then
    log "route conflict (openvpn redirect-gateway) — stopping $VPN_CONTAINER to attach"
    docker stop "$VPN_CONTAINER" >/dev/null
    docker network connect --ip "$VPN_IP" "$NET_NAME" "$VPN_CONTAINER"
    docker start "$VPN_CONTAINER" >/dev/null
    log "reattached and restarted; allow a moment for the tunnel to re-establish"
    return 0
  fi

  die "cannot attach while the tunnel is up: OpenVPN's redirect-gateway routes cover the whole address space.
       This is a one-time attach. Either re-run once with ALLOW_VPN_RESTART=1, or do it by hand:
         docker stop $VPN_CONTAINER
         docker network connect --ip $VPN_IP $NET_NAME $VPN_CONTAINER
         docker start $VPN_CONTAINER
       The attachment persists for the container's lifetime; Unraid drops it only when
       the container is recreated (any Docker-tab Apply), at which point this runs again."
}

attached=$(docker inspect -f "{{range \$k, \$v := .NetworkSettings.Networks}}{{if eq \$k \"$NET_NAME\"}}{{\$v.IPAddress}}{{end}}{{end}}" "$VPN_CONTAINER")
if [ -z "$attached" ]; then
  log "attaching $VPN_CONTAINER to $NET_NAME at $VPN_IP"
  attach
elif [ "$attached" != "$VPN_IP" ]; then
  log "re-attaching $VPN_CONTAINER: $attached -> $VPN_IP"
  docker network disconnect "$NET_NAME" "$VPN_CONTAINER"
  attach
fi

# --- 2b. the gateway must still have its own way out --------------------------
# $NET_NAME has NAT disabled by design, so it cannot carry the gateway's own
# traffic. If the container ends up with that as its default route -- e.g. its
# original network was dropped during a disconnect/recreate cycle -- it has no
# internet at all: openvpn cannot resolve or reach the VPN endpoint, and the
# tunnel never comes up. Catch it here rather than let it look like a DNS fault.
NET_GW=$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' "$NET_NAME")
def_gw=$(dex ip route 2>/dev/null | awk '/^default/{print $3; exit}')
if [ -n "$NET_GW" ] && [ "$def_gw" = "$NET_GW" ]; then
  nets=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$VPN_CONTAINER")
  die "$VPN_CONTAINER has no route to the internet: its default route is via $NET_GW,
       which is $NET_NAME -- a network with NAT deliberately disabled. The tunnel cannot
       come up from here, and openvpn will report 'Cannot resolve host address'.
       Networks attached: $nets
       It has lost its original network. Restore it in the Unraid Docker tab
       (OpenVPN-Client -> Edit -> Apply recreates it with its configured network),
       confirm the tunnel connects, then re-run this script with ALLOW_VPN_RESTART=1."
fi

# --- 3. forwarding + NAT + killswitch, inside the VPN container ---------------
fwd=$(dex cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)
[ "$fwd" = "1" ] || die "ip_forward=0 inside $VPN_CONTAINER. Add '--sysctl net.ipv4.ip_forward=1' to its Extra Parameters in the Unraid Docker tab and Apply (this recreates the container), then re-run."

if ! dex ip link show "$TUN_IF" >/dev/null 2>&1; then
  log "WARNING: $TUN_IF is down inside $VPN_CONTAINER — rules will be applied, but"
  log "         the killswitch will (correctly) block all workspace egress until it is up."
fi

# Rebuild a dedicated chain rather than appending: flush-and-refill is order-safe
# and idempotent, where bare -A/-C pairs drift as rules are added over time.
dex iptables -N WPILIB-FWD 2>/dev/null || true
dex iptables -F WPILIB-FWD
dex iptables -C FORWARD -j WPILIB-FWD 2>/dev/null || dex iptables -I FORWARD 1 -j WPILIB-FWD

# out through the tunnel: allowed. Return traffic: allowed.
dex iptables -A WPILIB-FWD -s "$SUBNET" -o "$TUN_IF" -j ACCEPT
dex iptables -A WPILIB-FWD -d "$SUBNET" -i "$TUN_IF" \
    -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
# KILLSWITCH — anything else touching the workspace subnet dies here. If tun0
# drops, this is what stops traffic falling out the LAN uplink instead.
dex iptables -A WPILIB-FWD -s "$SUBNET" -j DROP
dex iptables -A WPILIB-FWD -d "$SUBNET" -j DROP

dex iptables -t nat -C POSTROUTING -s "$SUBNET" -o "$TUN_IF" -j MASQUERADE 2>/dev/null \
  || dex iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$TUN_IF" -j MASQUERADE

log "gateway rules applied inside $VPN_CONTAINER"

# --- 4. host-side pinning: the workspace subnet may ONLY talk to the gateway ---
# Two jobs, one chain:
#   a) workspace-to-workspace isolation. Per-workspace netns fixes the *bind*
#      collision, but without this student A's NetworkTables server is still
#      reachable at B's 172.30.0.x:5810.
#   b) VPN bypass prevention. Workspaces hold NET_ADMIN (there is no declarative
#      per-container default gateway in Docker), so a student can point their own
#      default route at the bridge -- verified working in local testing, straight
#      out the host uplink. Docker also auto-MASQUERADEs every user-defined
#      network, so that egress succeeds unless it is stopped here. Dropping
#      everything from the subnet that is not addressed to the gateway makes the
#      bypass fail at the host regardless of what routes the container sets.
#
# Same-subnet traffic is bridged, but Docker sets net.bridge.bridge-nf-call-iptables=1
# so it still traverses DOCKER-USER. Flush-and-rebuild for order safety.
iptables -N WPILIB-HOST 2>/dev/null || true
iptables -F WPILIB-HOST
iptables -C DOCKER-USER -j WPILIB-HOST 2>/dev/null || iptables -I DOCKER-USER 1 -j WPILIB-HOST

# Gateway traffic is exempt. Note these match on *destination IP*, which only
# covers packets addressed to the gateway itself -- internet-bound packets merely
# use it as a next hop and carry the remote address, so they never match here.
# That is why there is no catch-all DROP below: it would eat all real egress.
iptables -A WPILIB-HOST -s "$VPN_IP" -d "$SUBNET" -j ACCEPT
iptables -A WPILIB-HOST -s "$SUBNET" -d "$VPN_IP" -j ACCEPT
# Workspace-to-workspace: denied. This is the rule that keeps student A's
# NetworkTables server off student B's network.
iptables -A WPILIB-HOST -s "$SUBNET" -d "$SUBNET" -j DROP

# Bypass prevention, the belt to enable_ip_masquerade=false's braces. Match on
# the *outbound interface*, not the destination: legitimate egress is bridged to
# the gateway container and so leaves via the same bridge it arrived on, whereas
# a student who re-points their default route at the bridge produces traffic
# routed off the bridge to the host uplink. Anything leaving the bridge with a
# workspace source address is therefore a bypass attempt.
#
# The Coder exception must sit ABOVE that DROP. The Coder container lives on a
# different bridge, so agent traffic legitimately leaves this one and would
# otherwise be dropped -- agents would never connect and workspaces would never
# finish starting. This is the only permitted off-bridge destination.
if [ -n "${CODER_IP:-}" ]; then
  iptables -A WPILIB-HOST -s "$SUBNET" -d "$CODER_IP" -j ACCEPT
  iptables -A WPILIB-HOST -s "$CODER_IP" -d "$SUBNET" \
      -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  log "Coder exception: $CODER_IP reachable from $SUBNET"
else
  # Not always needed. If the Coder access URL is public (or otherwise resolves to
  # an address reachable through the tunnel), agent traffic egresses via the VPN
  # like everything else and no exception applies -- which also matches what the
  # old shared-netns setup did, since workspaces inherited the VPN's routes there.
  # CODER_IP is only for a Coder reachable at a private address off this bridge.
  log "CODER_IP unset — agent traffic will egress through the tunnel."
  log "  Correct when the Coder access URL is public. If yours is a private/LAN"
  log "  address, set CODER_IP=<that address> or agents will not connect."
fi

BR_IF="br-$(docker network inspect -f '{{.Id}}' "$NET_NAME" | cut -c1-12)"
if ip link show "$BR_IF" >/dev/null 2>&1; then
  iptables -A WPILIB-HOST -s "$SUBNET" ! -o "$BR_IF" -j DROP
  log "bypass prevention bound to $BR_IF"
else
  log "WARNING: bridge $BR_IF not found — VPN bypass prevention NOT applied."
  log "         Workspaces hold NET_ADMIN and could re-route around the tunnel."
fi

log "host-side workspace isolation applied"
log "done — network=$NET_NAME subnet=$SUBNET gateway=$VPN_IP"
