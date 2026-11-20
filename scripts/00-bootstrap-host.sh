#!/usr/bin/env bash
# Install the exact tool versions the benchmark uses on a fresh Ubuntu 24.04 host.
set -euo pipefail
source "$(dirname "$0")/versions.env"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq docker.io jq python3 curl ca-certificates >/dev/null
systemctl enable --now docker

# kind nodes run many pods each; the defaults are too low for that.
cat >/etc/sysctl.d/99-kind.conf <<EOF
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=8192
EOF
sysctl --system >/dev/null

BIN=/usr/local/bin
curl -fsSLo $BIN/kind "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64"
curl -fsSLo $BIN/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
chmod +x $BIN/kind $BIN/kubectl

curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz -C /tmp
install /tmp/linux-amd64/helm $BIN/helm

for v in "$ISTIO_FROM" "$ISTIO_TO"; do
  curl -fsSL "https://github.com/istio/istio/releases/download/${v}/istioctl-${v}-linux-amd64.tar.gz" | tar -xz -C /tmp
  install /tmp/istioctl $BIN/istioctl-${v}
done

for v in "$LINKERD_FROM" "$LINKERD_TO"; do
  curl -fsSLo $BIN/linkerd-${v} "https://github.com/linkerd/linkerd2/releases/download/${v}/linkerd2-cli-${v}-linux-amd64"
  chmod +x $BIN/linkerd-${v}
done

docker pull -q "fortio/fortio:${FORTIO_VERSION}" >/dev/null
echo "bootstrap done"
