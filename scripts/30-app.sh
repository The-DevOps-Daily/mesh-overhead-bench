#!/usr/bin/env bash
# Deploy the benchmark namespace and the client -> a -> b -> c chain into the mesh.
# Usage: 30-app.sh <mesh>
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/versions.env
MESH=$1
kubectl create namespace bench --dry-run=client -o yaml | kubectl apply -f - >/dev/null
case "$MESH" in
  istio-sidecar) kubectl label ns bench istio-injection=enabled --overwrite ;;
  istio-ambient) kubectl label ns bench istio.io/dataplane-mode=ambient --overwrite ;;
  linkerd) kubectl annotate ns bench linkerd.io/inject=enabled --overwrite ;;
esac
sed "s/FORTIO_VERSION/${FORTIO_VERSION}/" k8s/app.yaml | kubectl apply -f - >/dev/null
kubectl -n bench rollout status deploy --timeout=300s
