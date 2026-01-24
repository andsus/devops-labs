#!/bin/bash
# =============================================================================
# Fix Calico Authorization and Certificate Issues
# =============================================================================
# When pods take 10+ minutes to initialize due to Calico authorization errors
# or certificate issues, this script refreshes credentials and certs.
#
# Symptoms:
#   - "connection is unauthorized: Unauthorized" in pod events
#   - FailedKillPod warnings with Calico plugin errors
#   - Slow pod initialization/termination
#   - Certificate errors in Calico component logs
# =============================================================================

set -e

echo "================================================"
echo "  Calico Authorization & Certificate Refresh"
echo "================================================"

# Check if calico-system namespace exists
if ! kubectl get namespace calico-system &> /dev/null; then
    echo "❌ calico-system namespace not found. Is Calico installed?"
    exit 1
fi

# -----------------------------------------------------------------------------
# Refresh Certificates
# -----------------------------------------------------------------------------
echo ""
echo "[1/4] Refreshing Calico certificates..."

# Delete certificate secrets to force regeneration
echo "   Deleting old certificate secrets..."
kubectl delete secret -n calico-apiserver calico-apiserver-certs 2>/dev/null && \
    echo "     ✅ Deleted calico-apiserver-certs" || \
    echo "     ℹ️  calico-apiserver-certs not found"

kubectl delete secret -n calico-system typha-certs 2>/dev/null && \
    echo "     ✅ Deleted typha-certs" || \
    echo "     ℹ️  typha-certs not found"

sleep 5

# -----------------------------------------------------------------------------
# Restart Components in Order
# -----------------------------------------------------------------------------
echo ""
echo "[2/4] Restarting Calico components..."

# Restart Typha first (manages connections)
echo "   Restarting Typha..."
kubectl rollout restart deployment/calico-typha -n calico-system 2>/dev/null || \
    echo "     ℹ️  Typha deployment not found"
sleep 5

# Restart Calico nodes (will reconnect to Typha with new certs)
echo "   Restarting Calico node daemonset..."
kubectl rollout restart daemonset/calico-node -n calico-system

# Restart controllers
echo "   Restarting kube-controllers..."
kubectl rollout restart deployment/calico-kube-controllers -n calico-system

# Restart API server if it exists
echo "   Restarting API server..."
kubectl rollout restart deployment/calico-apiserver -n calico-apiserver 2>/dev/null || \
    echo "     ℹ️  Calico API server not found"

# -----------------------------------------------------------------------------
# Wait for Readiness
# -----------------------------------------------------------------------------
echo ""
echo "[3/4] Waiting for components to be ready..."

echo "   Waiting for Calico nodes..."
kubectl rollout status daemonset/calico-node -n calico-system --timeout=300s

echo "   Waiting for kube-controllers..."
kubectl rollout status deployment/calico-kube-controllers -n calico-system --timeout=120s 2>/dev/null || \
    echo "     ⚠️  Controllers may need more time to stabilize"

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
echo ""
echo "[4/4] Verifying cluster health..."

CALICO_NODES_READY=$(kubectl get pods -n calico-system -l k8s-app=calico-node \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' | \
    grep -o "True" | wc -l | tr -d ' ')
CALICO_NODES_TOTAL=$(kubectl get daemonset/calico-node -n calico-system \
    -o jsonpath='{.status.desiredNumberScheduled}')

echo ""
echo "✅ Calico refresh complete!"
echo ""
echo "   Calico nodes ready: $CALICO_NODES_READY/$CALICO_NODES_TOTAL"
echo ""
echo "Your cluster networking should now be stable."
echo "If issues persist, try:"
echo "  1. Run: ./check-calico-health.sh"
echo "  2. Or restart cluster: k3d cluster stop calico-argocd && ./start-argocd-k3d-calico.sh"
echo ""