#!/bin/bash
# ============================================================================
# rail_routes.sh -- per-rail source routing for multi-rail (multi-VF) pods.
#
# The problem: a pod holding SEVERAL RoCE rails gets one /31 per VF (rail IP +
# leaf gateway) and every VF carries a route to the SAME fabric supernet (e.g.
# 192.168.117.0/24). Only one of those overlapping routes can win in the main
# routing table, so traffic sourced from rail N may egress rail M's gateway:
# ping between VF IPs fails, and RDMA/RoCE address resolution can pick the
# wrong port. (Single-VF pods -- the perftest pods -- have one route and are
# unaffected, which is why perftest passes while multi-rail ping fails.)
#
# The fix is classic source-based policy routing. For each rail:
#   table (100+N):  the rail's /31 link route + default via ITS OWN gateway
#   ip rule:        traffic FROM the rail's IP -> lookup table (100+N)
# plus LOOSE reverse-path filtering (rp_filter=2), so a reply arriving on the
# correct rail isn't dropped just because the main table points elsewhere.
#
# Idempotent -- safe to re-run any time. Needs a privileged pod (chart default).
# run_suite.sh --nccl runs this on both NCCL pods automatically.
#
# To test a specific rail afterwards, pin the source:  ping -I <rail-ip> <peer>
# (a bare `ping <peer>` still uses the main table and may pick another rail).
# ============================================================================
set -u

sysctl -qw net.ipv4.conf.all.rp_filter=2 2>/dev/null || true

i=0
ip -br -4 addr show \
  | awk '{sub(/@.*/, "", $1)} $1 != "lo" && $1 !~ /^eth0/ {print $1, $3}' \
  | while read -r ifc cidr; do
      [ -z "$ifc" ] && continue
      i=$((i + 1)); tbl=$((100 + i))
      ip="${cidr%/*}"; plen="${cidr#*/}"

      # Gateway: prefer whatever via-route the CNI wrote for this device; for a
      # /31 fall back to the other address of the pair (last octet XOR 1).
      gw="$(ip route show dev "$ifc" 2>/dev/null | awk '$2 == "via" {print $3; exit}')"
      if [ -z "$gw" ] && [ "$plen" = 31 ]; then
        gw="${ip%.*}.$(( ${ip##*.} ^ 1 ))"
      fi
      [ -z "$gw" ] && { echo "WARN: $ifc ($cidr): no gateway found, skipping"; continue; }

      # Link route: copy the kernel's connected route (any prefix length); for a
      # /31 we can also derive it (even address of the pair).
      net="$(ip route show dev "$ifc" scope link 2>/dev/null | awk '{print $1; exit}')"
      [ -z "$net" ] && [ "$plen" = 31 ] && net="${ip%.*}.$(( ${ip##*.} & ~1 ))/31"

      # This rail's own table: the local link + everything else via ITS gateway.
      [ -n "$net" ] && ip route replace "$net" dev "$ifc" src "$ip" table "$tbl"
      ip route replace default via "$gw" dev "$ifc" onlink table "$tbl"

      # Source rule: traffic FROM this rail's IP resolves in this rail's table.
      while ip rule del from "$ip" 2>/dev/null; do :; done
      ip rule add from "$ip" lookup "$tbl" pref "$tbl"

      sysctl -qw "net.ipv4.conf.$ifc.rp_filter=2" 2>/dev/null || true
      echo "rail $ifc: $ip -> table $tbl (default via $gw)"
    done

echo "per-rail source routing applied."
