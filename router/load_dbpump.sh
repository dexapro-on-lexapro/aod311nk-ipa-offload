#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Load aod_dbpump.ko on the AOD311NK with addresses taken from the running kernel.
#   usage: sh load_dbpump.sh /path/to/aod_dbpump.ko [period_us]
# The module stays inert (enable=0) until: echo Y > /sys/module/aod_dbpump/parameters/enable
KO=${1:?ko path}; PER=${2:-200}
grep -q "^aod_dbpump " /proc/modules && { echo "already loaded"; exit 0; }
A=$(awk '$3=="db_tx"{print $1}' /proc/kallsyms)
S=$(awk '$3=="__bss_start"{print $1}' /proc/kallsyms)
E=$(awk '$3=="__bss_stop"{print $1}' /proc/kallsyms)
# ioremaps made by rtl8168_request_event: "0xLO-0xHI size rtl8168_request_event+... ioremap"
R=$(grep "rtl8168_request_event" /proc/vmallocinfo | awk '{print $1}' | head -2)
L1=$(echo "$R" | sed -n 1p | cut -d- -f1); H1=$(echo "$R" | sed -n 1p | cut -d- -f2)
L2=$(echo "$R" | sed -n 2p | cut -d- -f1); H2=$(echo "$R" | sed -n 2p | cut -d- -f2)
[ -n "$A" ] && [ -n "$S" ] && [ -n "$E" ] && [ -n "$L1" ] || { echo "missing symbols/ranges"; exit 1; }
set -- db_tx_addr=0x$A bss_start=0x$S bss_end=0x$E db_lo1=$L1 db_hi1=$H1 period_us=$PER
[ -n "$L2" ] && set -- "$@" db_lo2=$L2 db_hi2=$H2
echo "insmod $KO $*"
insmod "$KO" "$@"
