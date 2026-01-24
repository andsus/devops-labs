#!/bin/bash
# =============================================================================
# Calico Health Check and Auto-Recovery Script
# =============================================================================
# This script checks the health of Calico components and automatically
# attempts to recover from common issues like certificate expiration.
#
# Usage: ./check-calico-health.sh
# =============================================================================

set -e

CLUSTER_NAME="${CLUSTER_NAME:-calico-argocd}"

echo "================================================"
echo "  Calico Health Check"
echo "================================================"

# Check if cluster is running
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Cluster is not accessible"
    echo "   Start with: k3d cluster start ${CLUSTER_NAME}"
    exit 1
fi

# -----------------------------------------------------------------------------
# Check Calico Node Pods
# -----------------------------------------------------------------------------
echo ""
echo "[1/5] Checking Calico node pods..."

CALICO_NODES_READY=$(kubectl get pods -n calico-system -l k8s-app=calico-node \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | \
    grep -o "True" | wc -l | tr -d ' ')
CALICO_NODES_TOTAL=$(kubectl get pods -n calico-system -l k8s-app=calico-node --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [ "$CALICO_NODES_READY" -lt "$CALICO_NODES_TOTAL" ]; then
    echo "⚠️  Calico nodes not all ready: $CALICO_NODES_READY/$CALICO_NODES_TOTAL"
    echo "🔄 Restarting Calico node daemonset..."
    kubectl rollout restart daemonset/calico-node -n calico-system
    
    echo "   Waiting for rollout to complete..."
    kubectl rollout status daemonset/calico-node -n calico-system --timeout=120s || true
else
    echo "✅ All Calico nodes ready: $CALICO_NODES_READY/$CALICO_NODES_TOTAL"
fi

# -----------------------------------------------------------------------------
# Check Calico Kube Controllers
# -----------------------------------------------------------------------------
echo ""
echo "[2/5] Checking Calico kube-controllers..."

CONTROLLERS_READY=$(kubectl get deployment -n calico-system calico-kube-controllers \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

if [ "$CONTROLLERS_READY" -eq 0 ]; then
    echo "⚠️  Calico kube-controllers not ready"
    
    # Check for common errors in logs
    if kubectl logs -n calico-system -l k8s-app=calico-kube-controllers --tail=50 2>/dev/null | \
       grep -qE "unauthorized|certificate|timeout"; then
        echo "🔄 Certificate or auth issues detected. Restarting..."
        kubectl rollout restart deployment/calico-kube-controllers -n calico-system
        sleep 10
    fi
else
    echo "✅ Calico kube-controllers ready"
fi

# -----------------------------------------------------------------------------
# Check Certificate Issues
# -----------------------------------------------------------------------------
echo ""
echo "[3/5] Checking for certificate errors..."

CERT_ERRORS=0

# Check Typha logs
if kubectl logs -n calico-system -l k8s-app=calico-typha --tail=100 2>/dev/null | \
   grep -qiE "certificate|unauthorized|x509"; then
    echo "⚠️  Certificate issues detected in Typha logs"
    CERT_ERRORS=1
fi

# Check Node logs
if kubectl logs -n calico-system -l k8s-app=calico-node --tail=100 2>/dev/null | \
   grep -qiE "unauthorized.*ClusterInformation"; then
    echo "⚠️  Authorization issues detected in Node logs"
    CERT_ERRORS=1
fi

if [ "$CERT_ERRORS" -eq 1 ]; then
    echo ""
    echo "🔄 Refreshing Calico certificates and components..."
    
    # Delete certificate secrets to force regeneration
    kubectl delete secret -n calico-apiserver calico-apiserver-certs 2>/dev/null || true
    kubectl delete secret -n calico-system typha-certs 2>/dev/null || true
    
    # Restart components in order
    echo "   Restarting Typha..."
    kubectl rollout restart deployment/calico-typha -n calico-system 2>/dev/null || true
    sleep 5
    
    echo "   Restarting Calico nodes..."
    kubectl rollout restart daemonset/calico-node -n calico-system
    sleep 5
    
    echo "   Restarting kube-controllers..."
    kubectl rollout restart deployment/calico-kube-controllers -n calico-system
    
    echo "   Waiting for components to stabilize..."
    sleep 15
else
    echo "✅ No certificate errors detected"
fi

# -----------------------------------------------------------------------------
# Check Ingress Controller
# -----------------------------------------------------------------------------
echo ""
echo "[4/5] Checking NGINX Ingress controller..."

INGRESS_READY=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | \
    grep -o "True" | wc -l | tr -d ' ')

if [ "$INGRESS_READY" -eq 0 ]; then
    echo "⚠️  Ingress controller not ready"
    echo "🔄 Restarting ingress controller..."
    kubectl rollout restart deployment/ingress-nginx-controller -n ingress-nginx
else
    echo "✅ Ingress controller ready"
fi

# -----------------------------------------------------------------------------
# Final Status
# -----------------------------------------------------------------------------
echo ""
echo "[5/5] Overall cluster status..."
echo ""

# Show problem pods
echo "Pods not in Running/Completed state:"
kubectl get pods -A | grep -v "Running\|Completed" | grep -v "NAMESPACE" || echo "  None - all pods healthy!"

echo ""
echo "================================================"
echo "  Health Check Complete"
echo "================================================"
echo ""
echo "If issues persist, try a full cluster restart:"
echo "  k3d cluster stop ${CLUSTER_NAME}"
echo "  k3d cluster start ${CLUSTER_NAME}"
echo "  ./start-argocd-k3d-calico.sh"
echo ""
