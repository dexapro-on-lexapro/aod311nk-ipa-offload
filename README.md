# AOD311NK IPA offload

This turns on IPA hardware offload for downlink traffic on the Airtel/Nokia **AOD311NK** 5G ODU (Qualcomm SDX65).
LAN download speed goes from about 40 Mbit/s, with the CPU stuck at 100% softirq, to about 500 Mbit/s.

## Why the speed was capped

- The stock LAN uses tagged VLAN 1999, so all traffic goes through the single Cortex-A7 CPU.
- With offload turned on, IPA only learns that a TX finished when the r8168 interrupt handler rings `db_tx`.
  Offloaded traffic raises almost no interrupts, so downloads slowed to a trickle.

## The fix

1. **Untagged path.** `eth0` joins `bridge0` untagged. `eth0.1999` stays as the management path. Both ports are set to `isolated on`.
2. **Switch registers (RTL8367C).** Set `0x7AA = 0x10` (accept untagged) and `0x2E = 0x4890` (egress keep). They are re-applied every 20 s.
3. **`aod_dbpump.ko`.** A kernel thread that writes `1` to `db_tx` every 200 µs.
4. **Firewall.** Accept `rmnet_data0 → bridge0` ESTABLISHED/RELATED traffic at the top of FORWARD, plus an ebtables guard on `eth0`.

## Files

| Path | Purpose |
|---|---|
| `router/apply-offload.sh` / `revert-offload.sh` | Turn offload on or off. Safe to run more than once. |
| `router/offload-boot.sh` | Runs at boot: starts rescue sshd :2227, waits for the stock setup, boot-loop guard, watcher. |
| `router/bounce.sh` | Reverts and re-applies offload so IPACM picks up a new client. |
| `router/load_dbpump.sh`, `aod_dbpump.ko` | Load the doorbell module, taking its addresses from `/proc/kallsyms`. |
| `router/start-rescue-sshd.sh` | Spare sshd on :2227 in its own systemd unit. |
| `kmod/` | Module source. Build against vanilla 5.4.265, then run `fix_this_module.sh` (the device's `struct module` is 0x240 bytes). |
| `mac/router-mode.sh` | Moves the Mac between `tagged` and `untagged` and triggers the bounce. |

## Install (on the router)

```sh
mkdir -p /systemrw/offload && cp router/* /systemrw/offload/
touch /systemrw/offload/ENABLED
# add to /systemrw/pwn.sh:
[ -f /systemrw/offload/ENABLED ] && timeout 10 systemd-run --no-block --unit=offload-boot /bin/sh /systemrw/offload/offload-boot.sh >/dev/null 2>&1
```

To turn it off: `rm /systemrw/offload/ENABLED` (it reverts within about 20 s).

## Daily use (on the Mac)

After every router reboot, run:

```sh
osascript -e 'do shell script "/bin/sh mac/router-mode.sh untagged" with administrator privileges'
```

IPACM only offloads a client that connects to the untagged port after a bounce.

## Cautions

- The router only accepts SSH from `192.168.0.182`. Keep the Mac on that address.
- Never restart `ipacm.service`, because sshd on :22 runs inside its cgroup. Use :2227 for risky changes.
- Upload still goes through the CPU, and loaded latency is about 330 ms (bufferbloat).

## Result

Median of 15 Ookla runs: **494 Mbit/s down**, 65 Mbit/s up, 0% loss.
