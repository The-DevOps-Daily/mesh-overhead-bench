#!/usr/bin/env bash
# Create a fresh 3-node kind cluster (1 control plane, 2 workers) named after the mesh.
# Usage: 10-cluster.sh <mesh>
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/versions.env
MESH=$1
CNI_BLOCK=""
if [ "$MESH" = cilium ]; then
  CNI_BLOCK=$'networking:\n  disableDefaultCNI: true'
fi
kind delete cluster --name bench >/dev/null 2>&1 || true
cat > /tmp/kind-$MESH.yaml <<YAML
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
$CNI_BLOCK
nodes:
- role: control-plane
- role: worker
  labels: {bench/node: w1}
- role: worker
  labels: {bench/node: w2}
YAML
kind create cluster --name bench --image "$KIND_NODE_IMAGE" --config /tmp/kind-$MESH.yaml --wait 0s
kind load docker-image --name bench hop:v1 >/dev/null   # fortio is pulled by the nodes
