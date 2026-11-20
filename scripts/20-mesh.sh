#!/usr/bin/env bash
# Install, upgrade or restart one mesh with its default settings.
# Usage: 20-mesh.sh <none|istio-sidecar|istio-ambient|linkerd|cilium> <install|upgrade|restart>
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/versions.env
MESH=$1 ACTION=$2

gateway_api() {
  kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
}

cilium_values=(--namespace kube-system --set image.pullPolicy=IfNotPresent --set ipam.mode=kubernetes
  --set encryption.enabled=true --set encryption.type=wireguard)

case "$MESH:$ACTION" in
  none:install) ;;
  none:upgrade) ;;  # nothing to upgrade; the app rollout below is the baseline
  none:restart)
    kubectl -n kube-system rollout restart ds/kindnet ds/kube-proxy
    kubectl -n kube-system rollout status ds/kindnet --timeout=180s
    kubectl -n kube-system rollout status ds/kube-proxy --timeout=180s ;;

  istio-sidecar:install|istio-ambient:install)
    profile=default; [ "$MESH" = istio-ambient ] && profile=ambient
    gateway_api
    istioctl-${ISTIO_FROM} install -y --set profile=$profile >/dev/null ;;
  istio-sidecar:upgrade|istio-ambient:upgrade)
    profile=default; [ "$MESH" = istio-ambient ] && profile=ambient
    istioctl-${ISTIO_TO} install -y --set profile=$profile >/dev/null
    kubectl -n istio-system rollout status deploy --timeout=300s
    if [ "$MESH" = istio-ambient ]; then
      kubectl -n istio-system rollout status ds/ztunnel --timeout=300s
      kubectl -n istio-system rollout status ds/istio-cni-node --timeout=300s
      kubectl -n bench rollout status deploy/waypoint --timeout=300s || true
    fi ;;
  istio-sidecar:restart|istio-ambient:restart)
    kubectl -n istio-system rollout restart deploy
    kubectl -n istio-system rollout status deploy --timeout=300s
    if [ "$MESH" = istio-ambient ]; then
      kubectl -n istio-system rollout restart ds/ztunnel ds/istio-cni-node
      kubectl -n istio-system rollout status ds/ztunnel --timeout=300s
      kubectl -n istio-system rollout status ds/istio-cni-node --timeout=300s
      kubectl -n bench rollout restart deploy/waypoint
      kubectl -n bench rollout status deploy/waypoint --timeout=300s
    fi ;;

  linkerd:install)
    gateway_api
    linkerd-${LINKERD_FROM} install --crds | kubectl apply -f - >/dev/null
    linkerd-${LINKERD_FROM} install | kubectl apply -f - >/dev/null
    linkerd-${LINKERD_FROM} check --wait 5m >/dev/null ;;
  linkerd:upgrade)
    linkerd-${LINKERD_TO} upgrade --crds | kubectl apply -f - >/dev/null
    linkerd-${LINKERD_TO} upgrade | kubectl apply -f - >/dev/null
    kubectl -n linkerd rollout status deploy --timeout=300s ;;
  linkerd:restart)
    kubectl -n linkerd rollout restart deploy
    kubectl -n linkerd rollout status deploy --timeout=300s ;;

  cilium:install)
    helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
    helm repo update cilium >/dev/null
    helm install cilium cilium/cilium --version ${CILIUM_FROM} "${cilium_values[@]}" >/dev/null
    kubectl -n kube-system rollout status ds/cilium --timeout=300s
    kubectl -n kube-system rollout status ds/cilium-envoy --timeout=300s ;;
  cilium:upgrade)
    # Pass the values again instead of --reuse-values: with --reuse-values Helm
    # kept the old image tags, so the "upgrade" restarted 1.20.4 pods.
    helm upgrade cilium cilium/cilium --version ${CILIUM_TO} "${cilium_values[@]}" >/dev/null
    kubectl -n kube-system rollout status ds/cilium --timeout=300s
    kubectl -n kube-system rollout status ds/cilium-envoy --timeout=300s
    kubectl -n kube-system rollout status deploy/cilium-operator --timeout=300s ;;
  cilium:restart)
    kubectl -n kube-system rollout restart ds/cilium ds/cilium-envoy deploy/cilium-operator
    kubectl -n kube-system rollout status ds/cilium --timeout=300s
    kubectl -n kube-system rollout status ds/cilium-envoy --timeout=300s
    kubectl -n kube-system rollout status deploy/cilium-operator --timeout=300s ;;
  cilium:no-encryption)
    helm upgrade cilium cilium/cilium --version ${CILIUM_TO} "${cilium_values[@]}" --set encryption.enabled=false >/dev/null
    # The chart does not roll the agents on a config change, so restart them.
    kubectl -n kube-system rollout restart ds/cilium
    kubectl -n kube-system rollout status ds/cilium --timeout=300s ;;
  *) echo "unknown $MESH $ACTION"; exit 1 ;;
esac
