#!/bin/sh
# Apply (idempotently) the full offload configuration on the AOD311NK:
#   1. aod_dbpump.ko loaded (inert)        4. RTL8367C port 1: accept-any (0x7AA=0x10) + egress KEEP (0x2E=0x4890)
#   2. eth0 joined to bridge0               5. pump enabled
#   3. bridge port isolation on eth0 + eth0.1999 (stops broadcast reflection)
# The tagged door (eth0.1999 in bridge0, VLAN 1999) is never touched.
# Safe to run repeatedly (the watcher calls it every 60 s); logs only what it changes.
#   usage: apply-offload.sh [quiet]
D=/systemrw/offload
Q=${1:-}
log() { echo "$(date '+%F %T') apply: $*"; }
master() { m=$(readlink /sys/class/net/$1/master 2>/dev/null); echo "${m##*/}"; }
reg() { timeout 10 /usr/sbin/switch reg r $1 2>/dev/null | tail -1 | grep -oE "0x[0-9a-f]+$"; }

# Guard for hosts that use BOTH doors (e.g. a Mac with vlan0 + en5 on DHCP/link-local): on the untagged
# port accept only ARP/IPv4 from the LAN subnet; drop everything else in nat PREROUTING, i.e. BEFORE the
# bridge learns the source MAC, so such chatter can't pull a host's MAC away from the tagged door.
guard_ok() {
  ebtables -t nat -L OFFLOAD_UNTAG >/dev/null 2>&1 || return 1
  ebtables -t nat -L PREROUTING 2>/dev/null | grep -q -- "-i eth0 -j OFFLOAD_UNTAG" || return 1
  [ "$(ebtables -t nat -L OFFLOAD_UNTAG 2>/dev/null | grep -cE 'RETURN|DROP')" = 4 ]
}
install_guard() {
  ebtables -t nat -N OFFLOAD_UNTAG 2>/dev/null
  ebtables -t nat -F OFFLOAD_UNTAG || return 1
  # DHCP DISCOVER/REQUEST (src 0.0.0.0 -> udp/67) so untagged clients can get a lease from dnsmasq on bridge0
  ebtables -t nat -A OFFLOAD_UNTAG -p IPv4 --ip-src 0.0.0.0 --ip-proto udp --ip-dport 67 -j RETURN || return 1
  ebtables -t nat -A OFFLOAD_UNTAG -p ARP --arp-ip-src 192.168.0.0/24 -j RETURN || return 1
  ebtables -t nat -A OFFLOAD_UNTAG -p IPv4 --ip-src 192.168.0.0/24 -j RETURN || return 1
  ebtables -t nat -A OFFLOAD_UNTAG -j DROP || return 1
  ebtables -t nat -L PREROUTING | grep -q -- "-i eth0 -j OFFLOAD_UNTAG" || \
    ebtables -t nat -I PREROUTING 1 -i eth0 -j OFFLOAD_UNTAG || return 1
  guard_ok
}

for d in eth0 eth0.1999 bridge0; do
  [ -d /sys/class/net/$d ] || { log "ABORT: $d missing"; exit 1; }
done
[ "$(master eth0.1999)" = bridge0 ] || { log "ABORT: tagged door eth0.1999 not in bridge0"; exit 1; }

# 1. pump module (inert until step 5)
if ! grep -q "^aod_dbpump " /proc/modules; then
  sh $D/load_dbpump.sh $D/aod_dbpump.ko 200 >/dev/null 2>&1 || { log "ABORT: pump load failed"; exit 1; }
  log "pump loaded: $(dmesg | grep 'aod_dbpump: db_tx' | tail -1 | sed 's/^\[[^]]*\] //')"
fi
P=/sys/module/aod_dbpump/parameters

# 1a. NAT return path: the vendor firewall can insert "! -i bridge+ -o bridge0 -j DROP" above the
#     "rmnet_data0 -> bridge0 ACCEPT" rule (seen after boot), which drops all WAN->LAN replies on the CPU
#     path (e.g. TCP handshakes before IPA has a NAT entry). Accept only replies, at the top.
if ! iptables -w -C FORWARD -i rmnet_data0 -o bridge0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
   || [ "$(iptables -w -S FORWARD | sed -n 2p)" != "-A FORWARD -i rmnet_data0 -o bridge0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT" ]; then
  iptables -w -D FORWARD -i rmnet_data0 -o bridge0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
  iptables -w -I FORWARD 1 -i rmnet_data0 -o bridge0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT && log "NAT reply rule at FORWARD top"
fi

# 1b. untagged-port guard (must exist before eth0 joins bridge0)
if ! guard_ok; then
  install_guard && log "untagged guard installed" || { log "ABORT: could not install untagged guard"; exit 1; }
fi

# 2 + 3. bridge membership and isolation (isolate the tagged port first)
if [ "$(bridge -d link show dev eth0.1999 2>/dev/null | grep -o 'isolated on')" != "isolated on" ]; then
  bridge link set dev eth0.1999 isolated on && log "isolated eth0.1999"
fi
if [ "$(master eth0)" != bridge0 ]; then
  ip link set eth0 nomaster 2>/dev/null
  ip link set eth0 master bridge0 && log "eth0 -> bridge0"
fi
if [ "$(bridge -d link show dev eth0 2>/dev/null | grep -o 'isolated on')" != "isolated on" ]; then
  bridge link set dev eth0 isolated on && log "isolated eth0"
fi

# 4. switch (BeaconMgr may reset these at boot / on Switch object access)
r=$(reg 1962); [ "$r" = "0x10" ] || { /usr/sbin/switch reg w 1962 16 >/dev/null 2>&1; log "0x7AA $r -> $(reg 1962)"; }
r=$(reg 46);   [ "$r" = "0x4890" ] || { /usr/sbin/switch reg w 46 18576 >/dev/null 2>&1; log "0x2E $r -> $(reg 46)"; }

# 5. pump on
[ "$(cat $P/enable 2>/dev/null)" = "Y" ] || { echo Y > $P/enable && log "pump enabled (period $(cat $P/period_us) us)"; }

[ -z "$Q" ] && log "state: eth0=$(master eth0) eth0.1999=$(master eth0.1999) 0x7AA=$(reg 1962) 0x2E=$(reg 46) pump=$(cat $P/enable) rings=$(cat $P/rings)"
exit 0
