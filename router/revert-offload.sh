#!/bin/sh
# Return the AOD311NK to its stock LAN state. Idempotent; safe from any state:
#   pump off + unloaded, switch regs stock (0x7AA=0x14, 0x2E=0x4880), isolation off,
#   eth0 back in br_gre, eth0.1999 in bridge0.
log() { echo "$(date '+%F %T') revert: $*"; }
master() { m=$(readlink /sys/class/net/$1/master 2>/dev/null); echo "${m##*/}"; }

echo N > /sys/module/aod_dbpump/parameters/enable 2>/dev/null
/usr/sbin/switch reg w 46 18560 >/dev/null 2>&1
/usr/sbin/switch reg w 1962 20 >/dev/null 2>&1
bridge link set dev eth0 isolated off 2>/dev/null
bridge link set dev eth0.1999 isolated off 2>/dev/null
if [ "$(master eth0)" != br_gre ]; then
  ip link set eth0 nomaster 2>/dev/null
  ip link set eth0 master br_gre
fi
[ "$(master eth0.1999)" = bridge0 ] || ip link set eth0.1999 master bridge0
ip link set eth0 up; ip link set eth0.1999 up
[ -n "$CLIENT_MAC" ] && bridge fdb del "$CLIENT_MAC" dev eth0 master 2>/dev/null
grep -q "^aod_dbpump " /proc/modules && rmmod aod_dbpump
while ebtables -t nat -D PREROUTING -i eth0 -j OFFLOAD_UNTAG 2>/dev/null; do :; done
ebtables -t nat -F OFFLOAD_UNTAG 2>/dev/null; ebtables -t nat -X OFFLOAD_UNTAG 2>/dev/null
log "done: eth0=$(master eth0) eth0.1999=$(master eth0.1999) module=$(grep -c '^aod_dbpump ' /proc/modules)"
