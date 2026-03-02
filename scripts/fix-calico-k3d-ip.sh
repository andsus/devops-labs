#!/bin/bash
# =============================================================================
# Fix Calico IP Autodetection on k3d (macOS/Linux)
# =============================================================================
# Problem: Calico defaults to 'first-found' IP detection, which may pick up
# the wrong interface (e.g. docker bridge IP) instead of the node IP on k3d.
# This causes internal connectivity issues (BGP peering fails, Typha unreachable).
#
# Fix: Patches Calico Installation to explicitly use 'eth0' interface.
# =============================================================================

set -e

echo "================================================"
echo "  Fixing Calico IP Autodetection..."
echo "================================================"

# Verify kubectl connectivity
if ! kubectl get nodes &> /dev/null; then
    echo "❌ kubectl cannot connect to the cluster."
    echo "   Ensure your context is set correctly (e.g. k3d-calico-argocd)"
    exit 1
fi

echo "[1/3] Patching Calico Installation resource..."
echo "      Setting nodeAddressAutodetectionV4.interface = eth0"
# Patching to remove firstFound and set interface to eth0
kubectl patch installation default --type=merge -p '{"spec":{"calicoNetwork":{"nodeAddressAutodetectionV4":{"firstFound":null,"interface":"eth0"}}}}'

echo ""
echo "[2/3] Restarting Calico components to apply changes..."

# Restart Typha (Deployment)
echo "   Restarting Calico Typha..."
kubectl rollout restart deployment/calico-typha -n calico-system

# Restart Calico Node (DaemonSet)
echo "   Restarting Calico Nodes..."
kubectl rollout restart daemonset/calico-node -n calico-system

echo ""
echo "[3/3] Waiting for rollout..."
kubectl rollout status deployment/calico-typha -n calico-system --timeout=120s
kubectl rollout status daemonset/calico-node -n calico-system --timeout=120s

echo ""
echo "✅ Calico configuration patched successfully!"
echo "   Verify connectivity with: kubectl get pods -n calico-system"
