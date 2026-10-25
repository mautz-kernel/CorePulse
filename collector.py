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
DEFAULTS = {"mountpoint": "/home", "interval_seconds": 2.0, "temperature_paths": []}


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
    previous = cpu_ticks()
    time.sleep(0.3 if args.once else opts["interval_seconds"])
    while True:
        current = cpu_ticks()
        try:
            print(json.dumps(sample(previous, current, opts, sensors), separators=(",", ":")), flush=True)
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
