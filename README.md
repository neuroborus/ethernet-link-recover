# ethernet-link-recover (yt6801)

Small recovery script and issue tracker for intermittent Ethernet link loss on Linux systems using the Motorcomm **YT6801** controller.

This repository is intended for cases where the wired interface does not fully disappear from the system, but periodically falls into a **`NO-CARRIER`** state and stops working until the driver or interface is reinitialized.

## Why this repository exists

On some Linux systems with the **Motorcomm YT6801** Ethernet controller, the wired connection can become unstable even when the cable remains physically connected.

Typical symptoms include:

- `ip link show <iface>` reports `NO-CARRIER`
- `cat /sys/class/net/<iface>/carrier` returns `0`
- NetworkManager shows the Ethernet interface as unavailable
- connectivity may return only after rebooting the machine
- Wi-Fi on the same machine, or other devices on the same router, continues to work normally

This repository documents a practical recovery script and provides a place to collect similar reports.

## Scope

This is **not** a driver implementation and **not** a universal fix.

It is a small recovery helper for systems where:

- the `yt6801` driver is present and loaded
- the Ethernet interface is detected by PCI
- the link intermittently drops into `NO-CARRIER`
- reloading the driver or reinitializing the interface restores connectivity

## Affected hardware and software

This repository is relevant if your system matches something close to the following:

- Ethernet controller: **Motorcomm YT6801**
- Linux driver: **`yt6801`**
- Network stack: **NetworkManager**
- Symptom: intermittent **link loss**, not just DHCP or DNS problems

You can verify this with:

```bash
lspci -nnk | grep -A3 -i ethernet
ethtool -i enp44s0
```

Expected output is similar to:

```text
Ethernet controller: Motorcomm Microelectronics YT6801 Gigabit Ethernet Controller
Kernel driver in use: yt6801
```

## Recovery script

Make it executable:

```bash
chmod +x ethernet-link-recover.sh
```

Run it:

```bash
./ethernet-link-recover.sh enp44s0
```

## What the script does

The script attempts to recover the wired link without rebooting the machine:

1. unloads the `yt6801` kernel module
2. loads it again
3. asks NetworkManager to reconnect the interface
4. prints the resulting link state

## Limitations

This script is only a workaround.

It may **not** help if:

- the controller is not detected at all
- the `yt6801` driver is missing or broken
- Secure Boot blocks the module
- the issue comes from a damaged cable, bad port, or physical layer problem
- the current kernel or DKMS package is incompatible with your system

## Compatibility notes

The **YT6801** Linux support story is still relatively young and depends strongly on the vendor driver/package stack.

This repository is especially relevant for systems where:

- TUXEDO OS or another vendor-tuned distro provides `yt6801`
- upstream kernel support is incomplete or evolving
- driver/package updates may affect stability

## Suggested diagnostics to collect

Before opening an issue, please collect and include the following:

```bash
uname -a
lsb_release -a || cat /etc/os-release
lspci -nnk | grep -A3 -i ethernet
ethtool -i enp44s0
ip link show enp44s0
cat /sys/class/net/enp44s0/carrier
nmcli device status
dkms status
modinfo yt6801 | grep -E '^(version|srcversion|filename):'
```

## Suggested reproduction details

When filing an issue, include:

- laptop / mini-PC / motherboard model
- Linux distribution and version
- kernel version
- `yt6801` module version
- whether the issue started after an update
- whether reboot restores the link
- whether `modprobe -r yt6801 && modprobe yt6801` restores the link
- whether Wi-Fi stays stable while Ethernet fails
- whether the interface disappears completely or only loses carrier

## Example issue title

```text
YT6801 on Linux intermittently falls into NO-CARRIER and requires module reload
```

## What this repository is for

This repository is meant to be:

- a practical non-reboot workaround
- a searchable place for users with the same controller and symptom set
- a collection point for reports related to `yt6801`, `NO-CARRIER`, and Linux Ethernet instability

## Search terms

- `yt6801 linux no carrier`
- `motorcomm yt6801 ubuntu ethernet disconnect`
- `yt6801 tuxedo os ethernet issue`
- `yt6801 driver unstable linux`
- `yt6801 networkmanager unavailable`
