#!/usr/bin/env bash
# Keep steady traffic on the chain while the mesh is upgraded or restarted, and
# log every request. Usage: 41-disruption.sh <mesh> <upgrade|restart> <config>
# upgrade: control plane to the new version, then (sidecar meshes and no mesh)
#          a rolling restart of hop-a/b/c so they pick up the new proxy.
# restart: restart every mesh component (or the CNI and kube-proxy for no mesh).
set -euo pipefail
cd "$(dirname "$0")/.."
MESH=$1 ACTION=$2 CONFIG=$3 LABEL=${4:-}
DUR=${DUR:-420}
OUT=results/$CONFIG/disruption-$ACTION$LABEL
mkdir -p "$OUT"
ev() { echo "$(date +%s.%N) $*" | tee -a "$OUT/events.txt"; }
: > "$OUT/events.txt"

scripts/podmap.sh "$OUT/podmap-before.json"
ev load-start
kubectl -n bench exec deploy/client -c fortio -- fortio load -quiet -c 8 -qps 200 -t "${DUR}s" \
  -access-log-file /dev/stderr -json - http://hop-a:8080/ > "$OUT/fortio.json" 2> "$OUT/access.raw" &
LOAD=$!
sleep 30
ev "$ACTION-start"
scripts/20-mesh.sh "$MESH" "$ACTION" > "$OUT/action.log" 2>&1
ev "$ACTION-mesh-done"
if [ "$ACTION" = upgrade ] && [[ "$MESH" =~ ^(none|istio-sidecar|linkerd)$ ]]; then
  # Let the new control plane settle before the workloads pick up the new proxy.
  # SETTLE=0 reproduces the pilot run that restarted the workloads straight away.
  sleep "${SETTLE:-30}"
  ev "settle-${SETTLE:-30}s-done"
fi
if [ "$ACTION" = upgrade ] && [[ "$MESH" =~ ^(none|istio-sidecar|linkerd)$ ]]; then
  ev app-rollout-start
  kubectl -n bench rollout restart deploy/hop-a deploy/hop-b deploy/hop-c >> "$OUT/action.log"
  kubectl -n bench rollout status deploy/hop-a deploy/hop-b deploy/hop-c --timeout=300s >> "$OUT/action.log" 2>&1 \
    || for d in hop-a hop-b hop-c; do kubectl -n bench rollout status deploy/$d --timeout=300s >> "$OUT/action.log"; done
  ev app-rollout-done
fi
ev actions-done
wait $LOAD || true
ev load-end
grep '^{"latency"' "$OUT/access.raw" | gzip -9 > "$OUT/access.jsonl.gz"
grep -v '^{"latency"' "$OUT/access.raw" > "$OUT/fortio.log" || true
rm "$OUT/access.raw"
scripts/podmap.sh "$OUT/podmap-after.json"
# Keep the load generator's own proxy log (sidecar meshes), to see why requests failed.
for c in linkerd-proxy istio-proxy; do
  kubectl -n bench logs deploy/client -c "$c" 2>/dev/null | gzip -9 > "$OUT/client-$c.log.gz" || true
  [ "$(zcat "$OUT/client-$c.log.gz" | head -c1 | wc -c)" = 0 ] && rm -f "$OUT/client-$c.log.gz"
done
# Record what is running now, so an upgrade that did not change the images shows up.
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}' > "$OUT/images-after.txt"
python3 - "$OUT" <<'PY'
import gzip, json, sys
out = sys.argv[1]
ev = [l.split(None, 1) for l in open(f"{out}/events.txt")]
rows = [json.loads(l) for l in gzip.open(f"{out}/access.jsonl.gz", "rt")]
bad = [r for r in rows if not r["ok"]]
lat = sorted(r["latency"] for r in rows if r["ok"])
done = float([t for t, e in ev if e.strip() == "actions-done"][0])
last = max(r["timestamp"] for r in rows) / 1e9
print(f"requests={len(rows)} failed={len(bad)} max_ok_latency_ms={lat[-1]*1000:.1f} "
      f"actions_finished_before_load_end={done < last}")
PY
