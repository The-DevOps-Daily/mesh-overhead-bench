#!/usr/bin/env bash
# Run every test for one mesh on a fresh cluster. Usage: 50-run-mesh.sh <mesh>
# Set PILOT=1 for a short smoke run that writes under results/pilot-*.
set -euo pipefail
cd "$(dirname "$0")/.."
MESH=$1
P=""
if [ "${PILOT:-0}" = 1 ]; then
  P="pilot-"; export REPS=1 DUR=10s
  UP_DUR=300 RS_DUR=200
else
  UP_DUR=${UP_DUR:-300} RS_DUR=${RS_DUR:-160}
fi
log() { echo "$(date -u +%FT%TZ) [$MESH] $*"; }

case "$MESH" in
  istio-ambient) MAIN=istio-ambient-waypoint ;;
  cilium) MAIN=cilium-wg-l7 ;;
  *) MAIN=$MESH ;;
esac
C=$P$MAIN

log cluster; scripts/10-cluster.sh "$MESH"
log install; scripts/20-mesh.sh "$MESH" install
log app; scripts/30-app.sh "$MESH"
log policy; scripts/31-policy.sh "$MAIN" "results/$C"
log upgrade-under-load; DUR=$UP_DUR scripts/41-disruption.sh "$MESH" upgrade "$C" "${UPRUN:+-$UPRUN}"
if [ "${ONLY:-}" = upgrade ]; then log done; exit 0; fi
if [[ "$MESH" =~ ^(istio-sidecar|linkerd)$ ]]; then
  # Give the load generator the new proxy too before measuring latency.
  kubectl -n bench rollout restart deploy/client && kubectl -n bench rollout status deploy/client --timeout=300s
fi
scripts/podmap.sh "results/$C/versions-podmap.json"
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{range .spec.containers[*]}{.image}{" "}{end}{range .spec.initContainers[*]}{.image}{" "}{end}{"\n"}{end}' > "results/$C/images.txt"
log latency; scripts/40-latency.sh "$C"
for r in 1 2 3; do
  log restart-under-load-$r; DUR=$RS_DUR scripts/41-disruption.sh "$MESH" restart "$C" "-$r"
done
log startup; scripts/42-startup.sh "$C"

if [ "$MESH" = istio-ambient ]; then
  log policy-l4; scripts/31-policy.sh istio-ambient-l4 "results/${P}istio-ambient-l4"
  log latency-l4; scripts/40-latency.sh "${P}istio-ambient-l4"
fi
if [ "$MESH" = cilium ]; then
  log policy-l4; scripts/31-policy.sh cilium-wg-l4 "results/${P}cilium-wg-l4"
  log latency-l4; scripts/40-latency.sh "${P}cilium-wg-l4"
  log no-encryption; scripts/20-mesh.sh cilium no-encryption
  scripts/31-policy.sh cilium-base "results/${P}cilium-base"
  log latency-base; scripts/40-latency.sh "${P}cilium-base"
fi
log done
