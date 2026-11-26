#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Switch this Mac's wired link to the AOD311NK between:
#   untagged : (tagged -> router bounce.sh -> untagged) offload path. en5 ("USB 10/100/1000 LAN") static 192.168.0.182/24 (the router firewall allows SSH only from .182), VLAN off,
#              USB LAN moved to the top of the service order (internet via the router, not Wi-Fi).
#   tagged   : management path (VLAN 1999, works with offload ON or OFF). vlan0 static 192.168.0.182/16,
#              en5 IPv4 off, Wi-Fi back on top (no internet via the router while offload is on).
#   status   : show current state (no admin needed).
# Needs root for untagged/tagged; run it through:
#   osascript -e 'do shell script "/bin/sh /path/router-mode.sh untagged" with administrator privileges'
N=/usr/sbin/networksetup
LAN="USB 10/100/1000 LAN"; VLAN="Untitled VLAN"; WIFI="Wi-Fi"

order_with_first() {   # $1 = service to put first; keeps all others in their current order
  first="$1"
  $N -listnetworkserviceorder | sed -n 's/^([0-9*]*) //p' > /tmp/.rm-order.$$
  set -- "$first"
  while IFS= read -r s; do [ "$s" = "$first" ] || set -- "$@" "$s"; done < /tmp/.rm-order.$$
  rm -f /tmp/.rm-order.$$
  $N -ordernetworkservices "$@"
}

to_tagged() {
  $N -setv4off "$LAN"
  $N -setv6off "$LAN"
  $N -setnetworkserviceenabled "$VLAN" on
  $N -setmanual "$VLAN" 192.168.0.182 255.255.0.0 192.168.0.1
  for i in $(seq 1 15); do /sbin/ifconfig vlan0 2>/dev/null | grep -q "inet 192.168.0.182" && /sbin/ping -c1 -t1 192.168.0.1 >/dev/null 2>&1 && break; sleep 1; done
}
KEY=${KEY:-$HOME/.ssh/aod311nk_offload_ed25519}
router() { /usr/bin/ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -p 2227 root@192.168.0.1 "$@"; }

case "$1" in
untagged)
  # IPACM only offloads a client that ARRIVES on the untagged port after a revert+re-apply, so:
  # tagged -> router bounce (if offload is enabled) -> untagged.
  to_tagged
  if router 'test -f /systemrw/offload/ENABLED' 2>/dev/null; then
    echo "router: $(router 'sh /systemrw/offload/bounce.sh' 2>&1 | tail -1)"
  else
    echo "router: offload not enabled (or unreachable) - untagged path will NOT work; staying tagged"; exit 1
  fi
  $N -setnetworkserviceenabled "$VLAN" off
  $N -setmanual "$LAN" 192.168.0.182 255.255.255.0 192.168.0.1
  $N -setdnsservers "$LAN" 192.168.0.1
  $N -setv6off "$LAN"
  order_with_first "$LAN"
  for i in $(seq 1 30); do /sbin/ifconfig en5 | grep -q "inet 192.168.0.182" && break; sleep 1; done
  echo "untagged: $(/sbin/ifconfig en5 | awk '/inet /{print $2}')" ;;
tagged)
  to_tagged
  order_with_first "$WIFI"
  echo "tagged: $(/sbin/ifconfig vlan0 | awk '/inet /{print $2}')" ;;
status)
  echo "order: $($N -listnetworkserviceorder | sed -n 's/^([0-9]*) //p' | head -3 | tr '\n' '|')"
  echo "en5:   $(/sbin/ifconfig en5 | awk '/inet /{print $2}')"
  echo "vlan0: $(/sbin/ifconfig vlan0 2>/dev/null | awk '/inet /{print $2}')"
  echo "default route: $(/sbin/route -n get default 2>/dev/null | awk '/interface:/{print $2}')" ;;
*) echo "usage: $0 untagged|tagged|status"; exit 2 ;;
esac
