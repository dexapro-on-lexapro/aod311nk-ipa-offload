#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# AOD311NK offload orchestrator. Started once per boot by ONE guarded line in /systemrw/pwn.sh:
#   [ -f /systemrw/offload/ENABLED ] && timeout 10 systemd-run --no-block --unit=offload-boot /bin/sh /systemrw/offload/offload-boot.sh >/dev/null 2>&1
# Runs as its own systemd unit (outside ipacm.service's cgroup).
#
# SSH safety:
#  - starts the rescue sshd (:2227, own unit) FIRST;
#  - waits for the stock topology AND sshd :22 before touching anything, then a further delay;
#  - boot counter is incremented BEFORE the module is loaded; >2 consecutive unhealthy boots -> ENABLED is
#    renamed and nothing more is applied (a crash loop therefore stops after at most 3 boots);
#  - the counter resets after 10 healthy minutes (ipacm active, sshd :22 listening, pump loaded);
#  - the tagged door (VLAN 1999) is never removed.
# Turn off at runtime: rm /systemrw/offload/ENABLED  (watcher reverts within about 60 s).
# Override delay for a rehearsal: OFFLOAD_DELAY=5 (environment).
D=/systemrw/offload
LOG=$D/offload-boot.log
[ -f $LOG ] && [ "$(wc -c < $LOG)" -gt 262144 ] && tail -c 131072 $LOG > $LOG.tmp && mv $LOG.tmp $LOG
exec >> $LOG 2>&1
log() { echo "$(date '+%F %T') boot: $*"; }
master() { m=$(readlink /sys/class/net/$1/master 2>/dev/null); echo "${m##*/}"; }

log "start pid $$ uptime $(cut -d' ' -f1 /proc/uptime)s"
sh $D/start-rescue-sshd.sh 2>&1 | tail -1

# wait (max 5 min) for the vendor stack: stock topology + pwn.sh's sshd :22
i=0
while [ $i -lt 60 ]; do
  [ "$(master eth0.1999)" = bridge0 ] && [ -n "$(master eth0)" ] \
    && netstat -tln 2>/dev/null | grep -q ":22 " && break
  i=$((i + 1)); sleep 5
done
[ $i -lt 60 ] || { log "stock topology / sshd :22 never appeared; not applying"; exit 0; }
sleep ${OFFLOAD_DELAY:-120}
[ -f $D/ENABLED ] || { log "ENABLED absent; exit"; exit 0; }

# boot guard (before anything risky)
n=$(cat $D/bootcount 2>/dev/null || echo 0)
n=$((n + 1)); echo $n > $D/bootcount; sync
if [ $n -gt 2 ]; then
  mv $D/ENABLED $D/ENABLED.disabled-by-guard; sync
  log "GUARD: $((n - 1)) consecutive unhealthy boots; offload DISABLED (renamed ENABLED)"
  exit 0
fi
log "bootcount=$n; applying"

if ! sh $D/apply-offload.sh; then
  log "apply failed -> revert"
  sh $D/revert-offload.sh
  exit 0
fi

# Per-client bounce: after a boot IPACM only gives dummy NAT (Private_IP=192.0.0.2, CPU path, ~6 Mbit/s) to a
# client until a revert + re-apply happens AFTER that client has been seen on the untagged port (reboot 4:
# a blind bounce before the client appeared did not help; a bounce after it did, ~330 Mbit/s). So the watcher
# bounces once per newly seen untagged MAC per boot (the client loses the untagged path for about 20 s once).
SEEN=/run/offload/seen-macs; mkdir -p /run/offload; : > $SEEN
# Keyed on MAC+IP: a known MAC with a new IP (e.g. a DHCP lease) was also left on dummy NAT until a bounce.
bounce_new_macs() {
  new=0
  for m in $(bridge fdb show dev eth0 2>/dev/null | grep -v -e permanent -e self -e "^33:33" -e "^01:" | awk '{print tolower($1)}'); do
    for ip in $(ip -4 neigh show dev bridge0 2>/dev/null | awk -v m="$m" 'tolower($3)==m && $1 ~ /^192\.168\.0\./ {print $1}'); do
      grep -qx "$m $ip" $SEEN || { echo "$m $ip" >> $SEEN; new=1; nm="$m $ip"; }
    done
  done
  [ $new = 1 ] || return 0
  [ -f $D/BOUNCE_NEW ] || { log "new untagged client $nm (auto-bounce off; router-mode.sh does tagged->bounce->untagged)"; return 0; }
  log "bounce: new untagged client $nm -> revert + re-apply so IPACM offloads it"
  sh $D/revert-offload.sh; sleep 5
  sh $D/apply-offload.sh || { log "re-apply failed -> revert"; sh $D/revert-offload.sh; exit 0; }
}

# watcher: health + re-assert every 20 s while ENABLED exists (health/bootcount logic unchanged)
while [ -f $D/ENABLED ]; do
  sleep 20
  bounce_new_macs
  up=$(cut -d. -f1 /proc/uptime)
  ok=1
  systemctl is-active -q ipacm || ok=0
  netstat -tln 2>/dev/null | grep -q ":22 " || ok=0
  grep -q "^aod_dbpump " /proc/modules || ok=0
  if [ $ok = 1 ] && [ "$up" -ge 600 ] && [ "$(cat $D/bootcount 2>/dev/null)" != 0 ]; then
    echo 0 > $D/bootcount; sync; log "healthy for 10 min: bootcount reset"
  fi
  [ $ok = 1 ] || log "health check failed (ipacm=$(systemctl is-active ipacm) ssh22=$(netstat -tln | grep -c ':22 ') pump=$(grep -c '^aod_dbpump ' /proc/modules))"
  sh $D/apply-offload.sh quiet
done
log "ENABLED removed -> revert"
sh $D/revert-offload.sh
