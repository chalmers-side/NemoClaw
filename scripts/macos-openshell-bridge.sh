#!/usr/bin/env bash
# Restore the loopback alias OpenShell uses for host.openshell.internal.
# Installed as a LaunchDaemon only when sudo -n works. Run as root.

set +x
set -euo pipefail

ip="${MACOS_OPENSHELL_BRIDGE_IP:-10.255.255.254}"
name="host.openshell.internal"

if ! ifconfig lo0 2>/dev/null | grep -q "inet ${ip} "; then
  ifconfig lo0 alias "$ip" netmask 255.255.255.255
fi

if ! grep -Eq "^${ip}[[:space:]]+${name}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
  printf '%s\t%s\t# nemoclaw-host-openshell-internal\n' "$ip" "$name" >>/etc/hosts
fi
