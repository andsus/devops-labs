#!/bin/bash
# =============================================================================
# Teardown ArgoCD kind cluster (Podman)
# =============================================================================

set -e

CLUSTER_NAME="${CLUSTER_NAME:-argocd}"
ARGOCD_HOST="${ARGOCD_HOST:-argocd.upandrunning.local}"

export KIND_EXPERIMENTAL_PROVIDER=podman

echo "================================================"
echo "  Teardown kind + Podman + ArgoCD"
echo "================================================"

echo ""
echo "[1/2] Deleting kind cluster '${CLUSTER_NAME}'..."
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    kind delete cluster --name "${CLUSTER_NAME}"
    echo "✅ Cluster deleted"
else
    echo "⚠️  Cluster '${CLUSTER_NAME}' does not exist"
fi

echo ""
echo "[2/2] Cleaning /etc/hosts..."
echo "To remove the hosts entry, run:"
echo "  sudo sed -i '' '/${ARGOCD_HOST}/d' /etc/hosts"
echo ""
echo "✅ Teardown complete"
