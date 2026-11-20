#!/usr/bin/env bash
# The first Cilium runs upgraded with `helm upgrade --reuse-values`, which kept the
# 1.20.4 images. Those results are kept under results/discarded-cilium-reuse-values/.
# This reruns every Cilium test with the fixed upgrade.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p results/discarded-cilium-reuse-values
for d in results/cilium-*; do mv "$d" results/discarded-cilium-reuse-values/; done
scripts/50-run-mesh.sh cilium || echo "FAILED cilium"
for run in 2 3; do
  ONLY=upgrade UPRUN=$run scripts/50-run-mesh.sh cilium || echo "FAILED cilium upgrade $run"
done
kind delete cluster --name bench
echo CILIUM RERUN DONE
