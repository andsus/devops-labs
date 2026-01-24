#!/bin/bash
# =============================================================================
# Teardown ArgoCD k3d cluster
# =============================================================================

set -e

CLUSTER_NAME="${CLUSTER_NAME:-argocd}"
ARGOCD_HOST="${ARGOCD_HOST:-argocd.upandrunning.local}"

echo "================================================"
echo "  Teardown k3d + ArgoCD"
echo "================================================"

echo ""
echo "[1/2] Deleting k3d cluster '${CLUSTER_NAME}'..."
if k3d cluster list | grep -q "${CLUSTER_NAME}"; then
    k3d cluster delete "${CLUSTER_NAME}"
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
