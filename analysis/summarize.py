#!/usr/bin/env python3
"""Turn results/<config>/ raw files into results/summary/*.csv and summary.json.

Every number in the write-up comes from the files this script writes.
Usage: python3 analysis/summarize.py [results_dir]
"""
import csv, glob, gzip, json, os, re, statistics as st, sys
from collections import defaultdict

R = sys.argv[1] if len(sys.argv) > 1 else "results"
OUT = os.path.join(R, "summary")
os.makedirs(OUT, exist_ok=True)
CONFIGS = ["none", "istio-sidecar", "istio-ambient-l4", "istio-ambient-waypoint", "linkerd",
           "cilium-base", "cilium-wg-l4", "cilium-wg-l7", "none-repeat"]
CONFIGS = [c for c in CONFIGS if os.path.isdir(os.path.join(R, c))]
PCT = {50.0: "p50", 90.0: "p90", 99.0: "p99", 99.9: "p999"}


def group(ns, pod, container):
    if ns == "bench":
        if pod.startswith("waypoint"):
            return "waypoint"
        if container in ("istio-proxy", "linkerd-proxy"):
            return "sidecar proxies"
        return "load generator" if container == "fortio" else "app"
    if ns == "istio-system":
        if pod.startswith("ztunnel"):
            return "node proxy"
        if pod.startswith("istio-cni"):
            return "node agent"
        if pod.startswith("istio-ingressgateway"):
            return "ingress gateway"
        return "control plane"
    if ns.startswith("linkerd"):
        return "control plane"
    if ns == "kube-system" and pod.startswith("cilium-envoy"):
        return "node proxy"
    if ns == "kube-system" and pod.startswith("cilium-operator"):
        return "control plane"
    if ns == "kube-system" and pod.startswith("cilium"):
        return "node agent"
    return "kubernetes system"


def load_map(path):
    m = {}
    for e in json.load(open(path)):
        if e["id"]:
            m[e["id"]] = e
    return m


def cpu_between(a, b, cmap):
    dt = b["t"] - a["t"]
    host = (b["host"]["busy_ticks"] - a["host"]["busy_ticks"]) / b["host"]["clk_tck"] / dt
    nodes = {n: (b["nodes"][n]["cpu_usec"] - a["nodes"][n]["cpu_usec"]) / 1e6 / dt for n in a["nodes"] if n in b["nodes"]}
    groups = defaultdict(float)
    for cid, s0 in a["containers"].items():
        s1 = b["containers"].get(cid)
        e = cmap.get(cid)
        if not s1 or not e or s0["cpu_usec"] is None:
            continue
        groups[group(e["ns"], e["pod"], e["container"])] += (s1["cpu_usec"] - s0["cpu_usec"]) / 1e6 / dt
    return host, nodes, dict(groups)


def mem_groups(snap, cmap):
    groups = defaultdict(float)
    for cid, s in snap["containers"].items():
        e = cmap.get(cid)
        if e and s["working_set_bytes"] is not None:
            groups[group(e["ns"], e["pod"], e["container"])] += s["working_set_bytes"] / 2**20
    nodes = {n: v["working_set_bytes"] / 2**20 for n, v in snap["nodes"].items()}
    return dict(groups), nodes


def spread(xs):
    xs = sorted(xs)
    return {"median": st.median(xs), "min": xs[0], "max": xs[-1], "n": len(xs)}


summary = {"latency": {}, "max_qps": {}, "cpu": {}, "memory_idle": {}, "startup": {}, "disruption": {}, "policy": {}}
lat_rows, cpu_rows = [], []

for c in CONFIGS:
    d = os.path.join(R, c, "latency")
    if not os.path.isdir(d):
        continue
    if not os.path.exists(os.path.join(d, "podmap-end.json")):
        print(f"skipping {c}: latency run not finished")
        continue
    cmap = load_map(os.path.join(d, "podmap.json"))
    cmap.update(load_map(os.path.join(d, "podmap-end.json")))
    per = defaultdict(lambda: defaultdict(list))
    cpu_per = defaultdict(lambda: defaultdict(list))
    for f in sorted(glob.glob(os.path.join(d, "qps*-rep*.json")) + glob.glob(os.path.join(d, "max-rep*.json"))):
        m = re.search(r"(qps\d+|max)-rep(\d+)\.json$", f)
        if not m:
            continue
        level, rep = m.group(1), int(m.group(2))
        j = json.load(open(f))
        pc = {PCT[float(p["Percentile"])]: p["Value"] * 1000 for p in j["DurationHistogram"]["Percentiles"]}
        codes = j.get("RetCodes", {})
        ok = codes.get("200", 0)
        total = j["DurationHistogram"]["Count"]
        row = {"config": c, "level": level, "rep": rep, "actual_qps": round(j["ActualQPS"], 1),
               "requests": total, "non_200": total - ok, **{k: round(v, 3) for k, v in pc.items()},
               "avg": round(j["DurationHistogram"]["Avg"] * 1000, 3)}
        a = json.load(open(f.replace(".json", ".cg0.json")))
        b = json.load(open(f.replace(".json", ".cg1.json")))
        host, nodes, groups = cpu_between(a, b, cmap)
        row["host_cores"] = round(host, 3)
        lat_rows.append(row)
        for k in ("p50", "p90", "p99", "p999", "actual_qps", "non_200"):
            per[level][k].append(row[k])
        cpu_per[level]["host"].append(host)
        for g, v in groups.items():
            cpu_per[level][g].append(v)
        for n, v in nodes.items():
            cpu_per[level]["node:" + n].append(v)
        cpu_rows.append({"config": c, "level": level, "rep": rep, "host_cores": round(host, 3),
                         **{"node:" + n: round(v, 3) for n, v in nodes.items()},
                         **{g: round(v, 3) for g, v in groups.items()}})
    summary["latency"][c] = {lvl: {k: spread(v) for k, v in m.items()} for lvl, m in per.items() if lvl != "max"}
    if "max" in per:
        summary["max_qps"][c] = spread(per["max"]["actual_qps"])
    summary["cpu"][c] = {lvl: {k: spread(v) for k, v in m.items()} for lvl, m in cpu_per.items()}
    idle = json.load(open(os.path.join(d, "idle-1.json")))
    a0 = json.load(open(os.path.join(d, "idle-0.json")))
    g, nodes = mem_groups(idle, cmap)
    ih, inodes, igroups = cpu_between(a0, idle, cmap)
    summary["memory_idle"][c] = {"groups_mib": {k: round(v, 1) for k, v in g.items()},
                                 "nodes_mib": {k: round(v, 1) for k, v in nodes.items()},
                                 "idle_host_cores": round(ih, 3),
                                 "idle_groups_cores": {k: round(v, 4) for k, v in igroups.items()}}
    # memory under load: last snapshot of the last 1000 qps run
    loaded = sorted(glob.glob(os.path.join(d, "qps1000-rep*.cg1.json")))
    if loaded:
        g2, n2 = mem_groups(json.load(open(loaded[-1])), cmap)
        summary["memory_idle"][c]["groups_mib_at_1000qps"] = {k: round(v, 1) for k, v in g2.items()}
        summary["memory_idle"][c]["nodes_mib_at_1000qps"] = {k: round(v, 1) for k, v in n2.items()}

for c in CONFIGS:
    p = os.path.join(R, c, "startup", "startup.json")
    if os.path.exists(p):
        rounds = json.load(open(p))
        xs = [x for r in rounds if not r["warmup"] for x in r["ready_s"]]
        xs.sort()
        summary["startup"][c] = {"pods": len(xs), "median_s": round(st.median(xs), 2),
                                 "p90_s": round(xs[int(0.9 * (len(xs) - 1))], 2), "max_s": round(xs[-1], 2),
                                 "min_s": round(xs[0], 2), "containers": rounds[-1]["containers"],
                                 "round_medians_s": [round(st.median(r["ready_s"]), 2) for r in rounds if not r["warmup"]]}
    pc = os.path.join(R, c, "policy-check.txt")
    if os.path.exists(pc):
        summary["policy"][c] = open(pc).read()

for c in CONFIGS:
    for d in sorted(glob.glob(os.path.join(R, c, "disruption-*"))):
        run = os.path.basename(d)[len("disruption-"):]
        action = run.split("-")[0]
        if not os.path.exists(os.path.join(d, "access.jsonl.gz")):
            continue
        ev = {}
        for line in open(os.path.join(d, "events.txt")):
            t, e = line.split(None, 1)
            ev.setdefault(e.strip(), float(t))
        rows = [json.loads(l) for l in gzip.open(os.path.join(d, "access.jsonl.gz"), "rt")]
        start = ev[f"{action}-start"]
        done = ev["actions-done"]
        before = sorted(r["latency"] * 1000 for r in rows if r["ok"] and r["timestamp"] / 1e9 < start)
        during = sorted(r["latency"] * 1000 for r in rows if r["ok"] and start <= r["timestamp"] / 1e9 <= done + 5)
        bad = [r for r in rows if not r["ok"]]
        secs = sorted({int(r["timestamp"] / 1e9) for r in bad})
        details = defaultdict(int)
        for r in bad:
            details[str(r.get("details", ""))[:60]] += 1
        slow = sum(1 for r in rows if r["ok"] and r["latency"] > 0.1)
        q = lambda xs, p: round(xs[min(len(xs) - 1, int(p * len(xs)))], 2) if xs else None
        summary["disruption"].setdefault(c, {})[run] = {
            "requests": len(rows), "failed": len(bad), "failed_pct": round(100 * len(bad) / len(rows), 3),
            "seconds_with_errors": len(secs),
            "first_error_after_action_s": round(min(r["timestamp"] for r in bad) / 1e9 - start, 1) if bad else None,
            "action_duration_s": round(done - start, 1),
            "ok_over_100ms": slow,
            "p99_before_ms": q(before, 0.99), "p99_during_ms": q(during, 0.99),
            "max_during_ms": round(during[-1], 1) if during else None,
            "failure_details": dict(details),
            "events_s": {k: round(v - start, 1) for k, v in ev.items()},
        }

with open(os.path.join(OUT, "latency-runs.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(lat_rows[0].keys()))
    w.writeheader()
    w.writerows(lat_rows)
keys = sorted({k for r in cpu_rows for k in r})
with open(os.path.join(OUT, "cpu-runs.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=["config", "level", "rep"] + [k for k in keys if k not in ("config", "level", "rep")])
    w.writeheader()
    w.writerows(cpu_rows)
json.dump(summary, open(os.path.join(OUT, "summary.json"), "w"), indent=1, default=float)

# Short console view
for c in CONFIGS:
    L = summary["latency"].get(c, {})
    parts = []
    for lvl in ("qps100", "qps500", "qps1000"):
        if lvl in L:
            parts.append(f"{lvl}: p50 {L[lvl]['p50']['median']:.2f} [{L[lvl]['p50']['min']:.2f}-{L[lvl]['p50']['max']:.2f}] "
                         f"p99 {L[lvl]['p99']['median']:.2f} [{L[lvl]['p99']['min']:.2f}-{L[lvl]['p99']['max']:.2f}]")
    mq = summary["max_qps"].get(c, {}).get("median")
    cpu = summary["cpu"].get(c, {}).get("qps1000", {}).get("host", {}).get("median")
    print(f"{c:24s} " + " | ".join(parts) + f" | max {mq and round(mq)} | host cores@1000 {cpu and round(cpu, 2)}")
for c, s in summary["startup"].items():
    print(f"startup {c:24s} median {s['median_s']}s p90 {s['p90_s']}s max {s['max_s']}s {s['containers']}")
for c, acts in summary["disruption"].items():
    for a, s in acts.items():
        print(f"disrupt {c:24s} {a:8s} failed {s['failed']}/{s['requests']} secs {s['seconds_with_errors']} "
              f"p99 before {s['p99_before_ms']} during {s['p99_during_ms']} max {s['max_during_ms']} took {s['action_duration_s']}s {s['failure_details']}")
