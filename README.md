# mesh-overhead-bench

The same three-hop HTTP chain on Kubernetes with no mesh, Istio sidecars, Istio ambient (ztunnel, plus one waypoint), Linkerd and Cilium (WireGuard plus an L7 policy). It measures latency at fixed request rates, CPU and memory for every component, pod startup time, and what an upgrade and a restart of the mesh do to live traffic.

Write-up: [Do you still need sidecars? Service mesh overhead, measured](https://devops-daily.com/posts/service-mesh-sidecars-vs-ambient-overhead-measured)

## Run it

You need a throwaway Ubuntu 24.04 amd64 host and a root shell (we used a 4 vCPU / 8 GB CPU-Optimized DigitalOcean droplet). Do not run it on a laptop you care about: it creates and deletes kind clusters and loads the CPU for about four hours.

```bash
git clone https://github.com/The-DevOps-Daily/mesh-overhead-bench && cd mesh-overhead-bench
scripts/00-bootstrap-host.sh                 # as root: docker, kind, kubectl, helm, istioctl, linkerd CLIs
docker build -t hop:v1 app/                  # the service used for every hop
scripts/60-run-all.sh 2>&1 | tee run.log     # every mesh, one at a time, ~4 h
python3 analysis/summarize.py results        # writes results/summary/
```

One mesh only: `scripts/50-run-mesh.sh <none|istio-sidecar|istio-ambient|linkerd|cilium>`. Add `PILOT=1` for a 15-minute smoke run.

## What runs

```text
fortio (w1) -> hop-a (w2) -> hop-b (w1) -> hop-c (w2)
```

A kind cluster with one control plane and two workers. Every call crosses a node. `hop` (in `app/`) is 63 lines of Go: it calls the next hop and returns 502 if that call fails. The one policy is on hop-b: only hop-a may call it, and, where the mesh can see HTTP, only with `GET` (Linkerd and Cilium also pin the path to `/`). Each mesh enforces it in its own way (`k8s/policy/`), and `31-policy.sh` checks it by calling hop-b directly from the client and recording the refusal in `results/<config>/policy-check.txt`.

| config | data plane | where the hop-b rule runs |
| --- | --- | --- |
| `none` | kindnet, no mesh | no rule |
| `istio-sidecar` | Envoy sidecar in every pod | hop-b's sidecar (L7) |
| `istio-ambient-l4` | ztunnel per node | ztunnel (L4: identity only, no method check) |
| `istio-ambient-waypoint` | ztunnel per node + one waypoint for hop-b | waypoint (L7) |
| `linkerd` | linkerd2-proxy sidecar in every pod | hop-b's proxy (L7) |
| `cilium-base` | Cilium eBPF, no encryption | no rule |
| `cilium-wg-l4` | Cilium eBPF + WireGuard | eBPF (L4: labels, no method check) |
| `cilium-wg-l7` | Cilium eBPF + WireGuard + node Envoy for hop-b | cilium-envoy (L7) |

Versions are pinned in `scripts/versions.env`. All meshes run with their install defaults; Cilium also gets `ipam.mode=kubernetes` and `image.pullPolicy=IfNotPresent` from Cilium's kind guide. Nothing was tuned for speed.

## Scripts

| script | does |
| --- | --- |
| `10-cluster.sh` | fresh kind cluster, loads the `hop` image |
| `20-mesh.sh` | install, upgrade or restart one mesh |
| `30-app.sh` | namespace, mesh label, the chain |
| `31-policy.sh` | applies the hop-b rule for a config and checks it |
| `40-latency.sh` | 5 rounds of 60 s at 100, 500 and 1,000 req/s (order rotated each round), then 3 x 30 s at max rate; cgroup snapshots around every run |
| `41-disruption.sh` | 200 req/s for several minutes while the mesh is upgraded (old to new version) or restarted; logs every request and the images running afterwards |
| `61-upgrade-repeats.sh` | upgrades again on fresh clusters, plus the no-wait variant for the sidecar meshes |
| `62-cilium-rerun.sh` | the Cilium rerun after the `--reuse-values` bug |
| `42-startup.sh` | 6 rounds of 10 new pods, time from `kubectl apply` to Ready (round 0 is warm-up) |
| `cgsnap.py` | reads cgroup v2 CPU and memory for every kind node and container, plus `/proc/stat` |
| `analysis/summarize.py` | turns `results/` into `results/summary/` |

## Results

All numbers below come from `results/summary/summary.json`, which `analysis/summarize.py` builds from the raw files. Host: DigitalOcean CPU-Optimized droplet, 4 dedicated vCPUs, 8 GB, Ubuntu 24.04, run on 2026-11-20.

Latency at 1,000 req/s through the chain, median of five 60 s runs (range in brackets), and the most req/s with no rate limit (median of three 30 s runs):

| config | p50 ms | p99 ms | max req/s | host cores at 1,000 req/s |
| --- | --- | --- | --- | --- |
| none | 1.60 [1.59-1.64] | 3.38 | 8,712 | 0.58 |
| cilium-base | 1.93 [1.88-2.07] | 3.84 | 6,974 | 0.73 |
| cilium-wg-l4 | 3.00 [2.89-3.03] | 5.16 | 4,362 | 0.95 |
| istio-ambient-l4 | 3.61 [3.56-3.62] | 6.46 | 3,958 | 0.98 |
| istio-ambient-waypoint | 5.77 [5.75-5.81] | 9.89 | 2,542 | 1.16 |
| cilium-wg-l7 | 6.25 [6.22-6.27] | 11.24 | 1,946 | 1.70 |
| linkerd | 7.48 [7.39-7.75] | 12.87 | 2,074 | 1.30 |
| istio-sidecar | 11.04 [10.81-11.21] | 19.56 | 1,298 | 2.34 |
| none-repeat (drift check, run last) | 1.59 [1.57-1.59] | 3.15 | 8,726 | 0.57 |

Pod startup (50 pods, `kubectl apply` to Ready, median): none 1.51 s, ambient 1.88 s, Cilium 2.05 s, Linkerd 4.95 s, Istio sidecar 5.21 s.

Upgrades and restarts under 200 req/s (failed requests per run, from the `disruption` block of `summary.json`):

| setup | upgrade, 30 s wait before app rollout | upgrade, no wait | restart |
| --- | --- | --- | --- |
| none (app rollout only) | 0, 0, 0 | | 0, 0, 0 |
| istio-sidecar | 0, 0, 0 | 47, 44 | 0, 0, 0 |
| istio-ambient-waypoint | 0, 0, 0 | | 0, 0, 0 |
| linkerd | 0, 0, 0 | 3,760, 3,984 (pilot: 3,600) | 0, 0, 0 |
| cilium-wg-l7 | 80, 24, 16 (plus `disruption-upgrade-early`: 48) | | 8, 7, 0 |

`upgrade-2` and `upgrade-3` ran on fresh clusters with `ONLY=upgrade` (`scripts/61-upgrade-repeats.sh`). The no-wait runs are `upgrade-nosettle-*` (`SETTLE=0`). Ambient and Cilium have no app rollout step, so the wait does not apply to them.

`results/discarded-cilium-reuse-values/` is the first Cilium run. It upgraded with `helm upgrade --reuse-values`, which kept the 1.20.4 images, so those numbers are for the wrong version and its "upgrades" only restarted pods. `scripts/62-cilium-rerun.sh` reran every Cilium test with the values passed explicitly. `results/cilium-wg-l7/disruption-upgrade-early` is a real 1.20.4 to 1.20.5 upgrade that ran with the fixed script before that rerun.

`results/pilot/` holds the short smoke runs made while building the scripts. They used earlier versions of the scripts (the Linkerd pilot restarted the workloads with no wait after the control plane upgrade) and are kept because the post cites one of them.

## Limits

- One host, one cluster per setup. kind nodes share the host's 4 cores, so a "node" is a container, not a machine. Absolute numbers will differ on real nodes; the comparison between configs is the point.
- One replica per hop for the latency runs. The disruption tests keep that, so the app's own rolling restart is part of the sidecar upgrade numbers; `none` runs the same rollout as the baseline.
- During the sidecar upgrade tests the load generator keeps its old proxy. It is restarted before the latency runs.
- Cilium's WireGuard work runs in kernel threads that no pod is charged for. Host CPU (from `/proc/stat`) counts it; the per-component numbers do not.

## License

MIT
