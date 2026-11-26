#!/bin/sh
# Revert + re-apply the offload config (used by the Mac's router-mode.sh while the Mac is on the TAGGED path).
# After a boot, IPACM only offloads a client that arrives on the untagged port AFTER such a cycle.
D=/systemrw/offload
[ -f $D/ENABLED ] || { echo "bounce: ENABLED absent, nothing to do"; exit 1; }
echo "$(date '+%F %T') bounce: requested via bounce.sh" >> $D/offload-boot.log
sh $D/revert-offload.sh >> $D/offload-boot.log 2>&1; sleep 5
sh $D/apply-offload.sh >> $D/offload-boot.log 2>&1 || { sh $D/revert-offload.sh >> $D/offload-boot.log 2>&1; echo "bounce: apply FAILED, reverted"; exit 1; }
tail -1 $D/offload-boot.log
