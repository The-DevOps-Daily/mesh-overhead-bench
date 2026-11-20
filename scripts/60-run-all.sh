#!/usr/bin/env bash
# The full matrix, one mesh at a time on one host. No mesh runs first and again
# last, so drift on the host shows up as a difference between the two.
set -uo pipefail
cd "$(dirname "$0")/.."
for m in none istio-sidecar istio-ambient linkerd cilium; do
  scripts/50-run-mesh.sh "$m" || echo "FAILED $m"
done
scripts/10-cluster.sh none && scripts/30-app.sh none && scripts/31-policy.sh none results/none-repeat \
  && scripts/40-latency.sh none-repeat || echo "FAILED none-repeat"
kind delete cluster --name bench
echo ALL DONE
