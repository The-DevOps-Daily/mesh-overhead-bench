#!/usr/bin/env python3
"""Time how long 10 new pods take from `kubectl apply` to Ready, 6 rounds.
Round 0 only warms the image caches and is kept but marked as warm-up.
Usage: 42-startup.sh <config>"""
import json, os, subprocess, sys, time

config = sys.argv[1]
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
out = f"results/{config}/startup"
os.makedirs(out, exist_ok=True)
JP = '{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\\n"}'

def kubectl(*a, **kw):
    return subprocess.run(["kubectl", "-n", "bench", *a], check=True, capture_output=True, text=True, **kw)

rounds = []
for r in range(6):
    w = subprocess.Popen(["kubectl", "-n", "bench", "get", "pods", "-l", "app=startup", "-w",
                          "-o", f"jsonpath={JP}"], stdout=subprocess.PIPE, text=True)
    time.sleep(1)
    t0 = time.time()
    kubectl("apply", "-f", "k8s/startup.yaml")
    ready = {}
    while len(ready) < 10:
        line = w.stdout.readline()
        if not line:
            break
        parts = line.split()
        if len(parts) == 2 and parts[1] == "True" and parts[0] not in ready:
            ready[parts[0]] = time.time() - t0
        if time.time() - t0 > 300:
            break
    w.kill()
    pods = json.loads(kubectl("get", "pods", "-l", "app=startup", "-o", "json").stdout)["items"]
    containers = sorted({c["name"] for p in pods for c in p["spec"].get("initContainers", []) + p["spec"]["containers"]})
    rounds.append({"round": r, "warmup": r == 0, "ready_s": sorted(ready.values()),
                   "containers": containers, "nodes": sorted(p["spec"].get("nodeName", "") for p in pods)})
    print(f"{config} round {r}: median {sorted(ready.values())[len(ready)//2]:.2f}s max {max(ready.values()):.2f}s pods={len(ready)} containers={containers}")
    kubectl("delete", "-f", "k8s/startup.yaml", "--wait=true")
    subprocess.run(["kubectl", "-n", "bench", "wait", "--for=delete", "pod", "-l", "app=startup", "--timeout=120s"],
                   capture_output=True)
    time.sleep(5)
json.dump(rounds, open(f"{out}/startup.json", "w"), indent=1)
