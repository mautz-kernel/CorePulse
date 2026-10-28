#!/usr/bin/env python3
"""CorePulse local read-only metrics collector, Python 3 stdlib only.

One JSON object per line on stdout. Does not invoke shell commands or use network.
The data stream stops when the QML Process is destroyed.
"""

import argparse
import json
import os
from pathlib import Path
import re
import sys
import time

BASE = Path(__file__).resolve().parent
DEFAULTS = {"mountpoint": "/home", "interval_seconds": 2.0, "temperature_paths": [],
            "battery_charge_limit_percent": None}


def config():
    result = DEFAULTS.copy()
    config_path = BASE / "settings.json"
    try:
        with config_path.open(encoding="utf-8") as handle:
            supplied = json.load(handle)
        if isinstance(supplied, dict):
            result.update({key: value for key, value in supplied.items() if key in DEFAULTS})
    except FileNotFoundError:
        pass  # Ohne Konfigurationsdatei die sicheren Standardwerte verwenden.
    except (OSError, ValueError) as exc:
        print(f"CorePulse: settings.json konnte nicht gelesen werden: {exc}", file=sys.stderr)
    if not isinstance(result["mountpoint"], str) or not result["mountpoint"].startswith("/"):
        result["mountpoint"] = "/home"
    if not isinstance(result["temperature_paths"], list):
        result["temperature_paths"] = []
    # Optionale BIOS-Ladegrenze (z.B. Dell 85 %) nur aus bewusster Einstellung.
    try:
        limit = int(result["battery_charge_limit_percent"])
        if not 50 <= limit <= 100:
            raise ValueError
        result["battery_charge_limit_percent"] = limit
    except (TypeError, ValueError):
        result["battery_charge_limit_percent"] = None
    try:
        result["interval_seconds"] = min(30, max(0.5, float(result["interval_seconds"])))
    except (TypeError, ValueError):
        result["interval_seconds"] = 2.0
    return result


def read_text(path):
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError):
        return ""


def cpu_ticks():
    overall = None
    cores = []
    for line in read_text("/proc/stat").splitlines():
        parts = line.split()
        if not parts:
            continue
        name = parts[0]
        if name != "cpu" and not re.fullmatch(r"cpu\d+", name):
            continue
        try:
            nums = [int(v) for v in parts[1:9]]
        except ValueError:
            continue
        if len(nums) < 4:
            continue
        total = sum(nums)
        idle = nums[3] + (nums[4] if len(nums) > 4 else 0)
        if name == "cpu":
            overall = (total, idle)
        else:
            cores.append((int(name[3:]), total, idle))
    cores.sort(key=lambda entry: entry[0])
    return overall, {i: (total, idle) for i, total, idle in cores}


def usage(current, previous):
    if current is None or previous is None:
        return 0.0
    total = current[0] - previous[0]
    idle = current[1] - previous[1]
    if total <= 0:
        return 0.0
    return round(max(0.0, min(100.0, 100.0 * (total - idle) / total)), 1)


def cpu_frequencies(cpu_ids):
    """Aktuelle Taktraten aus sysfs, gemeinsamer /proc/cpuinfo-Fallback.

    Auf Systemen ohne cpufreq sysfs /proc/cpuinfo nur EINMAL pro
    Messintervall lesen, statt einmal pro CPU-Thread.
    """
    result = {}
    missing = set()
    for cpu_id in cpu_ids:
        base = Path(f"/sys/devices/system/cpu/cpu{cpu_id}/cpufreq")
        for name in ("scaling_cur_freq", "cpuinfo_cur_freq"):
            value = read_text(base / name)
            if value:
                try:
                    result[cpu_id] = round(float(value) / 1000)
                    break
                except ValueError:
                    pass
        if cpu_id not in result:
            missing.add(cpu_id)

    if missing:
        for block in read_text("/proc/cpuinfo").split("\n\n"):
            values = dict((key.strip(), value.strip()) for key, value in
                          (line.split(":", 1) for line in block.splitlines() if ":" in line))
            try:
                cpu_id = int(values.get("processor", "-1"))
                if cpu_id in missing:
                    result[cpu_id] = round(float(values.get("cpu MHz", "0")))
            except ValueError:
                continue
    return result



def scaling_max_freq_mhz(cpu_id):
    """Aktuelles Kernel-Policy-Limit, u.a. von TLP veränderbar (keine Thermal-Diagnose)."""
    s = read_text(Path(f"/sys/devices/system/cpu/cpu{cpu_id}/cpufreq/scaling_max_freq"))
    try:
        return round(float(s) / 1000) if s else 0
    except ValueError:
        return 0


def intel_max_perf_pct():
    value = read_text("/sys/devices/system/cpu/intel_pstate/max_perf_pct")
    try:
        return int(value) if value else None
    except ValueError:
        return None


def thermal_counters(groups):
    """Intel-Kernelzähler seit Boot: Read-only, dürfen fehlen."""
    core_counts = []
    package_count = None
    for ids in groups:
        observed = []
        for cpu_id in ids:
            path = Path(f"/sys/devices/system/cpu/cpu{cpu_id}/thermal_throttle")
            val = read_text(path / "core_throttle_count")
            if val.isdigit():
                observed.append(int(val))
            pkg = read_text(path / "package_throttle_count")
            if package_count is None and pkg.isdigit():
                package_count = int(pkg)
        core_counts.append(max(observed) if observed else None)
    return {
        "available": package_count is not None or any(v is not None for v in core_counts),
        "package_count": package_count,
        "core_counts": core_counts,
    }

def mem_gib():
    values = {}
    for line in read_text("/proc/meminfo").splitlines():
        if ":" not in line:
            continue
        key, rest = line.split(":", 1)
        try:
            values[key] = int(rest.strip().split()[0])
        except (ValueError, IndexError):
            continue
    total = values.get("MemTotal", 0)
    available = values.get("MemAvailable", values.get("MemFree", 0))
    used = max(0, total - available)
    return round(used / 1048576, 2), round(total / 1048576, 2)


def disk_gib(path):
    try:
        stats = os.statvfs(path)
        return round(stats.f_bavail * stats.f_frsize / 1073741824, 2)
    except OSError:
        return None


# Slow-path detail collection: no external commands, no root privileges.
# Run every 10 seconds rather than at the 2-second CPU sampling interval.
def top_memory_processes(limit=10):
    """Highest per-process RSS values, not unique/proportional memory use."""
    ranked = []
    for folder in Path("/proc").iterdir():
        if not folder.name.isdecimal():
            continue
        try:
            with (folder / "status").open(encoding="utf-8", errors="replace") as handle:
                name = None
                rss_kib = 0
                for line in handle:
                    if line.startswith("Name:"):
                        name = line.partition(":")[2].strip()
                    elif line.startswith("VmRSS:"):
                        rss_kib = int(line.split()[1])
                    if name and rss_kib:
                        break
            if name and rss_kib > 0:
                ranked.append({
                    "pid": int(folder.name),
                    "name": name,
                    "rss_mib": round(rss_kib / 1024, 1),
                })
        except (OSError, ValueError, IndexError):
            # Process ended, procfs is restricted, or metadata is unreadable.
            continue
    ranked.sort(key=lambda item: item["rss_mib"], reverse=True)
    return ranked[:limit]


def decode_mount_field(s):
    """Decode mountinfo escaping (spaces, backslashes and control chars)."""
    return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), s)


def mounted_volumes(limit=18):
    """Local mounted volumes only; omit pseudo filesystems and bind duplicates."""
    result = []
    seen_mountpoints = set()
    # Whitelist supported local disk filesystems, plus block-device-backed FS.
    local_types = {"ext2", "ext3", "ext4", "btrfs", "xfs", "f2fs", "zfs",
                   "vfat", "exfat", "ntfs", "ntfs3", "fuseblk", "bcachefs"}
    for line in read_text("/proc/self/mountinfo").splitlines():
        try:
            left, right = line.split(" - ", 1)
            left_cols = left.split()
            right_cols = right.split()
            mountpoint = decode_mount_field(left_cols[4])
            fs_type = right_cols[0]
            device = decode_mount_field(right_cols[1])
            if (fs_type not in local_types or mountpoint in seen_mountpoints
                    or not mountpoint.startswith("/")
                    or mountpoint.startswith(("/proc/", "/sys/", "/dev/",
                                             "/var/lib/containers/", "/var/lib/docker/"))
                    or (mountpoint.startswith("/run/") and
                        not mountpoint.startswith("/run/media/"))):
                continue
            # Skip bind-mounted directory clones; allow btrfs subvolumes.
            root_field = decode_mount_field(left_cols[3])
            if root_field != "/" and fs_type != "btrfs":
                continue
            stats = os.statvfs(mountpoint)
            blocks = stats.f_blocks
            if blocks <= 0:
                continue
            total = blocks * stats.f_frsize / (1024 ** 3)
            avail = stats.f_bavail * stats.f_frsize / (1024 ** 3)
            used = (blocks - stats.f_bfree) * stats.f_frsize / (1024 ** 3)
            seen_mountpoints.add(mountpoint)
            result.append({
                "mountpoint": mountpoint,
                "source": device,
                "fstype": fs_type,
                "total_gib": round(total, 1),
                "used_gib": round(used, 1),
                "free_gib": round(avail, 1),
                "used_pct": round(100 * used / total, 1) if total else 0,
            })
        except (ValueError, OSError, IndexError):
            continue
    result.sort(key=lambda item: (item["mountpoint"] != "/", item["mountpoint"] != "/home", item["mountpoint"]))
    return result[:limit]



def remaining_battery_hours(now, full, rate, status, charge_limit_pct):
    """Momentaufnahme aus zusammengehörigen sysfs-Einheiten (uWh/uW oder uAh/uA).

    Ohne erkennbares Ladeziel keine scheinbar genaue Zeit bis 100 % ausgeben:
    ein BIOS-Limit kann deutlich darunter liegen. Beim Entladen zählt der
    aktuelle Energievorrat unabhängig vom eingestellten Ladestopp.
    """
    if rate <= 0 or full <= 0 or now < 0:
        return None
    if status == "discharging":
        hours = now / rate
    elif status == "charging" and charge_limit_pct is not None:
        target = full * charge_limit_pct / 100.0
        remaining = target - now
        if remaining <= 0:
            return None
        hours = remaining / rate
    else:
        return None
    if 0 < hours <= 72:
        return round(hours, 3)
    return None


def power_supply_status(base=Path("/sys/class/power_supply"), charge_limit_percent=None):
    """Laptop-Stromversorgung aus sysfs lesen, ohne externe Werkzeuge.

    Die Systembatterie wird bevorzugt; Bluetooth-/Eingabegeräteakkus
    duerfen nicht versehentlich die Laptop-Anzeige uebernehmen.
    """
    try:
        supplies = sorted(base.iterdir())
    except OSError:
        supplies = []
    battery = None
    ac_mains = None
    ac_other = None
    for supply in supplies:
        kind = read_text(supply / "type").lower()
        if kind in ("mains", "usb", "usb_c", "usb_pd"):
            online = read_text(supply / "online")
            if online in ("0", "1"):
                # Die echte Netzteil-Schnittstelle hat Vorrang vor USB.
                if kind == "mains":
                    ac_mains = (ac_mains is True or online == "1")
                else:
                    ac_other = (ac_other is True or online == "1")
        elif kind == "battery":
            if read_text(supply / "present") == "0":
                continue
            scope = read_text(supply / "scope").lower()
            if scope == "device":
                continue
            if battery is None or supply.name.startswith("BAT"):
                battery = supply
    ac_online = ac_mains if ac_mains is not None else ac_other
    result = {
        "present": battery is not None, "percent": None,
        "status": "", "ac_online": ac_online,
        "health_pct": None, "time_hours": None,
        "charge_limit_pct": None, "power_w": None,
    }
    if battery is None:
        return result
    percent = read_text(battery / "capacity")
    try:
        pct = int(percent)
        if 0 <= pct <= 100:
            result["percent"] = pct
    except ValueError:
        pass
    result["status"] = read_text(battery / "status")
    # Wenn der Kernel eine Ladeschwelle kennt, hat sie Vorrang vor dem
    # optionalen Benutzerwert; 100 % kann auch "kein Kernel-Limit" bedeuten.
    threshold = read_text(battery / "charge_control_end_threshold")
    try:
        kernel_limit = int(threshold)
        if not 50 <= kernel_limit <= 100:
            kernel_limit = None
    except ValueError:
        kernel_limit = None
    # Ein explicit gesetztes 85-%-BIOS-Ziel darf 100 % aus sysfs
    # überschreiben, da manche Firmware nur das Standardziel ausweist.
    if kernel_limit is not None and kernel_limit < 100:
        result["charge_limit_pct"] = kernel_limit
    elif charge_limit_percent is not None:
        result["charge_limit_pct"] = charge_limit_percent
    elif kernel_limit is not None:
        result["charge_limit_pct"] = kernel_limit

    # Sysfs energy_now/full [uWh], power_now [uW]. Alternative charge [uAh]
    # and current [uA] yield the same duration ratio.
    for stored, full, original, rate in (("energy_now", "energy_full", "energy_full_design", "power_now"),
                                          ("charge_now", "charge_full", "charge_full_design", "current_now")):
        try:
            now = float(read_text(battery / stored))
            capacity = float(read_text(battery / full))
            speed = float(read_text(battery / rate))
        except ValueError:
            continue
        if stored == "energy_now" and speed >= 0:
            result["power_w"] = round(speed / 1000000, 1)
        design = read_text(battery / original)
        try:
            design_capacity = float(design)
            if design_capacity > 0:
                result["health_pct"] = round(100 * capacity / design_capacity, 1)
        except ValueError:
            pass
        result["time_hours"] = remaining_battery_hours(
            now, capacity, abs(speed), result["status"].lower(),
            result["charge_limit_pct"])
        break
    return result


def physical_core_groups(cpu_ids):
    """Gruppiert logische Linux-CPUs nach CPU-Package + physischem Core.

    Nicht blind cpu0..cpu3 als physische Kerne interpretieren:
    die Nummerierung der Hyperthreading-Geschwister ist nicht garantiert.
    """
    groups = {}
    for cpu_id in sorted(cpu_ids):
        base = Path(f"/sys/devices/system/cpu/cpu{cpu_id}/topology")
        package = read_text(base / "physical_package_id")
        core = read_text(base / "core_id")
        if package and core:
            key = ("topology", package, core)
        else:
            # Fehlen die Topologieinformationen, nichts zusammenraten.
            key = ("cpu", cpu_id)
        groups.setdefault(key, []).append(cpu_id)
    return list(groups.values())


def summed_ticks(ticks, ids):
    available = [ticks[cpu_id] for cpu_id in ids if cpu_id in ticks]
    if not available:
        return None
    return (sum(t[0] for t in available), sum(t[1] for t in available))


def sensor_list(custom_paths):
    # Explizite Konfiguration hat Vorrang (ein Sensor, nicht zwei).
    if custom_paths:
        path = next((Path(s) for s in custom_paths if isinstance(s, str) and s), None)
        return [("CPU", path)] if path is not None else []

    choices = []
    for folder in sorted(Path("/sys/class/hwmon").glob("hwmon*")):
        chip = read_text(folder / "name").lower()
        if chip not in ("coretemp", "k10temp", "zenpower"):
            continue
        for file in folder.glob("temp*_input"):
            label = read_text(folder / file.name.replace("_input", "_label")).lower()
            if chip == "coretemp" and "package" in label:
                rank = 0
            elif chip in ("k10temp", "zenpower") and "tdie" in label:
                rank = 0
            elif chip in ("k10temp", "zenpower") and "tctl" in label:
                rank = 1
            else:
                continue
            choices.append((rank, str(file), file, chip + " " + label))
    choices.sort(key=lambda x: (x[0], x[1]))
    return [(choices[0][3], choices[0][2])] if choices else []


def read_temps(sensors):
    values = []
    for label, path in sensors:
        raw = read_text(path)
        try:
            val = float(raw) / 1000.0
        except ValueError:
            continue
        if -30.0 <= val <= 150.0:
            values.append({"label": label, "c": round(val, 1), "path": str(path)})
    return values


def sample(previous, current, opts, sensors):
    prev_total, prev_cores = previous
    cur_total, cur_cores = current
    groups = physical_core_groups(cur_cores.keys())
    freq_by_cpu = cpu_frequencies(cur_cores.keys())
    # Aktuell gesetzte cpufreq-Obergrenze (z.B. auto-cpufreq, TLP oder manuell).
    # Ein sysfs-Policy-Limit ist keine garantierte Turbo- oder Throttle-Frequenz.
    policy_by_cpu = {cpu_id: scaling_max_freq_mhz(cpu_id) for cpu_id in cur_cores}

    # Alle verfügbaren logischen Threads für die Detailansicht.
    threads = [{
        "id": cpu_id,
        "usage": usage(cur_cores[cpu_id], prev_cores.get(cpu_id)),
        "mhz": freq_by_cpu.get(cpu_id, 0),
        "max_mhz": policy_by_cpu.get(cpu_id, 0),
    } for cpu_id in sorted(cur_cores)]

    # Vier *physische* Kerne für die gemeinsame Grafik im Panel.
    cores = []
    for index, cpu_ids in enumerate(groups[:4], start=1):
        cores.append({
            "id": index,
            "cpu_ids": cpu_ids,
            "usage": usage(summed_ticks(cur_cores, cpu_ids), summed_ticks(prev_cores, cpu_ids)),
            "mhz": max((freq_by_cpu.get(cpu_id, 0) for cpu_id in cpu_ids), default=0),
        })

    used, total = mem_gib()
    return {
        "cpu_total": usage(cur_total, prev_total),
        "cores": cores,
        "threads": threads,
        "mem_used_gib": used,
        "mem_total_gib": total,
        "mountpoint": opts["mountpoint"],
        "disk_free_gib": disk_gib(opts["mountpoint"]),
        "temps": read_temps(sensors),
        "policy_max_mhz": max(policy_by_cpu.values(), default=0),
        "intel_max_perf_pct": intel_max_perf_pct(),
        "thermal": thermal_counters(groups),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--once", action="store_true", help="Generate one sample for diagnostics")
    args = parser.parse_args()
    opts = config()
    sensors = sensor_list(opts["temperature_paths"])
    # Cache slower process/mount details so the 2-second CPU sampling stays cheap.
    detail_cache = {"top_processes": [], "mounts": [], "battery": {}}
    last_detail_check = -float("inf")
    previous = cpu_ticks()
    time.sleep(0.3 if args.once else opts["interval_seconds"])
    while True:
        current = cpu_ticks()
        try:
            now = time.monotonic()
            if now - last_detail_check >= 10.0:
                detail_cache = {"top_processes": top_memory_processes(),
                                "mounts": mounted_volumes(),
                                "battery": power_supply_status(
                                    charge_limit_percent=opts["battery_charge_limit_percent"])}
                last_detail_check = now
            output = sample(previous, current, opts, sensors)
            output.update(detail_cache)
            print(json.dumps(output, separators=(",", ":")), flush=True)
        except Exception as exc:
            print(f"CorePulse: Fehler bei Messung: {exc}", file=sys.stderr, flush=True)
        previous = current
        if args.once:
            break
        time.sleep(opts["interval_seconds"])


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
