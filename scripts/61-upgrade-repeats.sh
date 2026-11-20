#!/usr/bin/env bash
# An upgrade can only happen once per cluster, so repeat it on fresh clusters
# to see whether the first result was luck. Writes disruption-upgrade-2 and -3.
set -uo pipefail
cd "$(dirname "$0")/.."
for run in 2 3; do
  for m in none istio-sidecar istio-ambient linkerd cilium; do
    ONLY=upgrade UPRUN=$run scripts/50-run-mesh.sh "$m" || echo "FAILED $m upgrade $run"
  done
done
# The pilot restarted the workloads the moment the control plane rollout finished.
# Reproduce that on purpose for the two sidecar meshes.
for run in 1 2; do
  for m in istio-sidecar linkerd; do
    SETTLE=0 ONLY=upgrade UPRUN=nosettle-$run scripts/50-run-mesh.sh "$m" || echo "FAILED $m upgrade nosettle-$run"
  done
done
kind delete cluster --name bench
echo REPEATS DONE
