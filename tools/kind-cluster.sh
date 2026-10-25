#!/usr/bin/env bash
#
# Creates a kind cluster for the consortium and loads the Besu image into it.
#
# The image is loaded rather than pulled, so the cluster works offline and so
# the version is exactly the one the Compose stack runs. That is also why
# pullPolicy must not be Always: the node would try to fetch an image it
# already has and fail.
set -euo pipefail

CLUSTER="${KIND_CLUSTER:-loc-consortium}"
BESU_IMAGE="${BESU_IMAGE:-hyperledger/besu:26.8.1}"

command -v kind >/dev/null || { echo "kind is required: https://kind.sigs.k8s.io"; exit 1; }

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "cluster $CLUSTER already exists"
else
  echo "==> creating cluster $CLUSTER"
  # A single node. Six Besu pods on one kind node is already demanding on a
  # laptop also running the Compose stack; multiple kind nodes would add
  # scheduling realism and memory pressure in equal measure, and the
  # scheduling is not what this deployment is demonstrating.
  cat <<EOF | kind create cluster --name "$CLUSTER" --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
EOF
fi

echo "==> loading $BESU_IMAGE"
docker image inspect "$BESU_IMAGE" >/dev/null 2>&1 || docker pull "$BESU_IMAGE"
kind load docker-image "$BESU_IMAGE" --name "$CLUSTER"

echo "==> loading busybox for the init container"
docker pull busybox:1.37 >/dev/null
kind load docker-image busybox:1.37 --name "$CLUSTER"

echo
kubectl cluster-info --context "kind-$CLUSTER"
