#!/usr/bin/env bash
# Switch the hop-b policy to one variant, then prove it: the chain works and a
# direct call from the client to hop-b is refused.
# Usage: 31-policy.sh <config> <outdir>
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=$1 OUT=$2
mkdir -p "$OUT"
case "$CONFIG" in
  none|cilium-base) kubectl -n bench delete ciliumnetworkpolicy hop-b --ignore-not-found >/dev/null 2>&1 || true ;;
  istio-sidecar) kubectl apply -f k8s/policy/istio-sidecar.yaml ;;
  istio-ambient-waypoint)
    kubectl -n bench delete authorizationpolicy hop-b --ignore-not-found
    kubectl apply -f k8s/policy/istio-ambient-waypoint.yaml
    kubectl -n bench rollout status deploy/waypoint --timeout=300s 2>/dev/null || { sleep 10; kubectl -n bench rollout status deploy/waypoint --timeout=300s; }
    kubectl -n bench label svc hop-b istio.io/use-waypoint=waypoint --overwrite ;;
  istio-ambient-l4)
    kubectl -n bench label svc hop-b istio.io/use-waypoint- 2>/dev/null || true
    kubectl -n bench delete authorizationpolicy hop-b-l7 --ignore-not-found
    kubectl -n bench delete gateway waypoint --ignore-not-found
    kubectl apply -f k8s/policy/istio-ambient-l4.yaml ;;
  linkerd) kubectl apply -f k8s/policy/linkerd.yaml ;;
  cilium-wg-l4) kubectl apply -f k8s/policy/cilium-l4.yaml ;;
  cilium-wg-l7) kubectl apply -f k8s/policy/cilium-l7.yaml ;;
  *) echo "unknown config $CONFIG"; exit 1 ;;
esac
sleep 15
{
  echo "config=$CONFIG"
  echo "--- client -> hop-a (chain, expect 200)"
  kubectl -n bench exec deploy/client -c fortio -- fortio curl -timeout 3s http://hop-a:8080/ 2>&1 | grep -E "^HTTP|ok$|code" | head -3 || true
  echo "--- client -> hop-b directly (expect refused when a policy is set)"
  kubectl -n bench exec deploy/client -c fortio -- fortio curl -timeout 3s http://hop-b:8080/ 2>&1 | grep -E 'HTTP/|"err"|reset|timeout|refused|terminated' | cut -c1-400 || true
  if [[ "$CONFIG" == cilium-* ]]; then
    # Prove what the datapath is doing: L7 redirects, WireGuard peers, bytes through cilium_wg0.
    p=$(kubectl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=bench-worker -o name)
    echo "--- cilium status on bench-worker (hop-b's node)"
    kubectl -n kube-system exec "$p" -c cilium-agent -- cilium-dbg status | grep -E "Proxy Status|Encryption|KubeProxyReplacement|Routing"
    echo "--- cilium_wg0 counters before and after 1,000 chain requests"
    docker exec bench-worker ip -s link show cilium_wg0 2>&1 | sed -n '3,6p' || true
    kubectl -n bench exec deploy/client -c fortio -- fortio load -quiet -qps 0 -n 1000 -c 4 http://hop-a:8080/ >/dev/null 2>&1
    docker exec bench-worker ip -s link show cilium_wg0 2>&1 | sed -n '3,6p' || true
  fi
} | tee "$OUT/policy-check.txt"
