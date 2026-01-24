#!/bin/bash
# =============================================================================
# Smart Start Script for Calico ArgoCD Cluster
# =============================================================================
# This script starts the k3d cluster and performs health validation,
# automatically refreshing Calico components to prevent stale certificates.
#
# Usage: ./start-argocd-k3d-calico.sh
# =============================================================================

set -e

CLUSTER_NAME="${CLUSTER_NAME:-calico-argocd}"

echo "================================================"
echo "  Starting ${CLUSTER_NAME} Cluster"
echo "================================================"

# Start the cluster
echo ""
echo "[1/6] Starting k3d cluster..."
k3d cluster start "$CLUSTER_NAME"

# Wait for nodes to be ready
echo ""
echo "[2/6] Waiting for nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s

# Refresh Calico components to avoid certificate issues
echo ""
echo "[3/6] Refreshing Calico components (prevents stale certificates)..."

echo "   Restarting Calico nodes..."
kubectl rollout restart daemonset/calico-node -n calico-system

echo "   Restarting Calico kube-controllers..."
kubectl rollout restart deployment/calico-kube-controllers -n calico-system

# Wait for Calico to stabilize
echo ""
echo "[4/6] Waiting for Calico to stabilize..."
kubectl wait --for=condition=Ready pods -l k8s-app=calico-node \
    -n calico-system --timeout=180s || echo "   (Some Calico nodes may still be starting)"

# Restart ingress controller
echo ""
echo "[5/6] Restarting NGINX Ingress controller..."
kubectl rollout restart deployment/ingress-nginx-controller -n ingress-nginx

kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=120s || echo "   (Ingress controller may still be starting)"

# Wait for ArgoCD
echo ""
echo "[6/6] Checking ArgoCD status..."
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=argocd-server \
    -n argocd --timeout=120s || echo "   (ArgoCD may still be starting)"

echo ""
echo "================================================"
echo "  ✅ Cluster Started Successfully"
echo "================================================"
echo ""
echo "Cluster health summary:"
kubectl get pods -A | grep -v "Running.*1/1\|Running.*2/2\|Completed" | head -n 20 || echo "  All pods healthy!"

echo ""
echo "Access ArgoCD at: https://argocd.upandrunning.local"
echo ""
echo "Run health check: ./check-calico-health.sh"
echo ""
