#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Start an extra sshd on :2227 in its OWN systemd unit (offload-sshd.service),
# outside ipacm.service's cgroup. The normal sshd on :22/:2226 is spawned by
# pwn.sh inside ipacm.service, so if ipacm ever stops or crashes, systemd kills
# them; this one survives. Runtime only (gone after reboot). Idempotent.
# Reachable through either LAN door: ssh -p 2227 root@192.168.0.1
# (INPUT already accepts every port from 192.168.0.182).
PORT=2227
if netstat -tln 2>/dev/null | grep -q ":$PORT "; then echo "sshd :$PORT already listening"; exit 0; fi
mkdir -p /var/run/sshd
systemctl reset-failed offload-sshd 2>/dev/null
systemd-run --unit=offload-sshd -p Restart=always -p RestartSec=10 \
  /usr/sbin/sshd -D -p $PORT \
  -h /configs/ssh/ssh_host_ed25519_key -h /configs/ssh/ssh_host_rsa_key \
  -o AllowUsers=root -o AuthorizedKeysFile=/configs/ssh/authorized_keys \
  -o PasswordAuthentication=no -o StrictModes=no -o PidFile=/var/run/sshd-$PORT.pid
sleep 2
netstat -tln 2>/dev/null | grep ":$PORT " && echo "OK: offload-sshd on :$PORT"
