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

### Prerequisites

- **Bash** (script uses `mapfile`, process substitution, and strict mode).
- **NetworkManager** (`nmcli` must work for your user when using `sudo`).
- **ethtool** (to read the driver name for the chosen interface).
- **sudo** privileges for `ip link`, `modprobe`, and (typically) `nmcli connection up`.

Make it executable:

```bash
chmod +x ethernet-link-recover.sh
```

Run it (no arguments — the Ethernet interface is auto-detected):

```bash
sudo ./ethernet-link-recover.sh
```

### What the script does (execution order)

The script runs a fixed pipeline. Steps below match the implementation in `ethernet-link-recover.sh`.

1. **Detect the Ethernet interface** (`detect_iface`):
   - Lists devices NetworkManager reports as type `ethernet`.
   - If there is exactly one, that name is used.
   - If there are several, prefers the interface whose `ethtool -i` driver is **`yt6801`**.
   - Otherwise prefers an Ethernet device NM marks as connected, connecting, disconnected, or unavailable.
   - If it still cannot pick one interface safely, the script exits with an error.

2. **Read the kernel driver name** for that interface (`detect_driver` via `ethtool -i`). This may be empty on unusual systems; driver reload is skipped when empty.

3. **Resolve the NetworkManager connection UUID** (`find_or_create_profile_uuid`), in order:
   - **Active on this NIC:** `nmcli -g GENERAL.CON-UUID device show <iface>`, but only if the profile passes the sanity checks in step 4.
   - **Else** first matching row in `nmcli connection show --active` where `TYPE` is `ethernet` or `802-3-ethernet` and `DEVICE` equals `<iface>`, again only if step 4 passes.
   - **Else** scan all saved connections by UUID: `802-3-ethernet`, `connection.interface-name` equals `<iface>`, not a bridge/slave (no `connection.master` / `connection.slave-type`). Prefer a profile whose **`connection.id` equals the interface name** (e.g. `enp44s0`); otherwise use the first such match.
   - **Else** create **`autorecover-<iface>`**: DHCP, autoconnect, bound to `<iface>`, and use its UUID.

4. **Profile sanity checks** (standalone wired profile, used for active/device UUID and consistent with the saved scan):
   - `connection.type` is `802-3-ethernet`.
   - `connection.interface-name` is empty, `--`, or equals `<iface>` (so NM does not try to apply the profile to the wrong netdev).
   - `connection.slave-type` and `connection.master` are unset or `--` (skips Docker/bridge port profiles that break a plain `connection up`).

5. **Log** interface name, driver, `connection.id`, and UUID for the chosen profile; log **carrier** from `/sys/class/net/<iface>/carrier` before any recovery.

6. **Soft link reset** (`soft_recover`): `ip link set <iface> down`, sleep 1s, `ip link set <iface> up`.

7. **Wait for carrier** (up to **10** seconds): polls `carrier`; only then proceeds to activation so NM does not fail with “no carrier” immediately after the flap.

8. **Bring the profile up** (`bring_up_profile`): `nmcli connection up uuid <UUID> ifname <iface>` (UUID disambiguates profiles; `ifname` pins the device), then sleep 2s. Failures are non-fatal (`|| true`) so you still get the final status dump.

9. **If carrier never returned in step 7:** unload the driver (`modprobe -r <driver>`), reload (`modprobe <driver>`), run **soft reset** again, wait up to **15** seconds for carrier, then repeat step 8 if carrier appeared; otherwise log that carrier is still absent.

10. **Print diagnostics:** `nmcli device status`, `ip link show <iface>`, and the final `carrier` value.

### Design notes (why it looks this way)

- **UUID, not name:** `connection.id` / connection names are not guaranteed unique in NetworkManager. Activation uses **`nmcli connection up uuid …`** so the correct object is selected.
- **`ifname` on `connection up`:** without it, NM can associate the profile with the wrong device (e.g. a bridge) on some setups.
- **Wait for carrier:** after `ip link down/up`, link sense can lag; activating too early produces transient “no carrier” errors even when the link recovers moments later.
- **No `nmcli -f …,connection.interface-name` on bulk `connection show`:** that field list is invalid for a single tabular query; saved profiles are inspected per-UUID with `nmcli -g`.

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
