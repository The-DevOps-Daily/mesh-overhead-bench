#!/usr/bin/env bash
# Save container id -> namespace/pod/container, so cgroup snapshots can be labelled.
# Usage: podmap.sh <out.json>
kubectl get pods -A -o json | jq '[.items[] | . as $p
  | ((.status.containerStatuses // []) + (.status.initContainerStatuses // []))[]
  | {id: (.containerID // "" | sub("^containerd://"; "")), ns: $p.metadata.namespace,
     pod: $p.metadata.name, container: .name, node: $p.spec.nodeName}]' > "$1"
