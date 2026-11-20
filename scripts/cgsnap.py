#!/usr/bin/env python3
"""Snapshot CPU and memory counters for every kind node and every container in it.

Reads cgroup v2 files on the host, so it sees mesh agents, proxies and apps the
same way, plus /proc/stat for host-wide CPU (which also counts kernel work such
as softirq and WireGuard crypto that no pod cgroup is charged for).
Usage: cgsnap.py <out.json>
"""
import glob, json, os, re, subprocess, sys, time

def read_kv(path):
    out = {}
    try:
        for line in open(path):
            k, v = line.split()
            out[k] = int(v)
    except OSError:
        pass
    return out

def read_int(path):
    try:
        return int(open(path).read().strip())
    except (OSError, ValueError):
        return None

def cg_stats(d):
    cpu = read_kv(os.path.join(d, "cpu.stat"))
    mem = read_int(os.path.join(d, "memory.current"))
    mstat = read_kv(os.path.join(d, "memory.stat"))
    ws = None if mem is None else mem - mstat.get("inactive_file", 0)
    return {"cpu_usec": cpu.get("usage_usec"), "mem_bytes": mem, "working_set_bytes": ws}

def main(out):
    ids = subprocess.run(["docker", "ps", "--no-trunc", "--format", "{{.ID}} {{.Names}}"],
                         capture_output=True, text=True, check=True).stdout.split("\n")
    names = dict(l.split() for l in ids if l.strip())
    snap = {"t": time.time(), "nodes": {}, "containers": {}}
    stat = open("/proc/stat").readline().split()[1:]
    vals = list(map(int, stat))
    # user nice system idle iowait irq softirq steal
    snap["host"] = {"busy_ticks": sum(vals[:3]) + sum(vals[5:8]), "total_ticks": sum(vals[:8]),
                    "clk_tck": os.sysconf("SC_CLK_TCK"), "ncpu": os.cpu_count()}
    for d in glob.glob("/sys/fs/cgroup/system.slice/docker-*.scope"):
        cid = re.search(r"docker-([0-9a-f]+)\.scope", d).group(1)
        node = names.get(cid)
        if not node or not node.startswith("bench-"):
            continue
        snap["nodes"][node] = cg_stats(d)
        for c in glob.glob(d + "/**/cri-containerd-*.scope", recursive=True):
            ccid = re.search(r"cri-containerd-([0-9a-f]+)\.scope", c).group(1)
            s = cg_stats(c)
            s["node"] = node
            snap["containers"][ccid] = s
    json.dump(snap, open(out, "w"))

if __name__ == "__main__":
    main(sys.argv[1])
