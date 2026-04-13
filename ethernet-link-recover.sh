#!/usr/bin/env bash
set -euo pipefail

IFACE="${1:-enp44s0}"
MODULE="yt6801"

echo "[*] Reloading module: ${MODULE}"
sudo modprobe -r "${MODULE}" || true
sleep 1
sudo modprobe "${MODULE}"

echo "[*] Reconnecting interface: ${IFACE}"
sleep 2
nmcli device connect "${IFACE}" || true

echo "[*] Current link state"
ip link show "${IFACE}"
cat "/sys/class/net/${IFACE}/carrier" || true
