#!/bin/bash
# =============================================================================
# Argo Workflows Setup for k3d (macOS Silicon)
# =============================================================================
# Creates:
#   - Argo Workflows namespace
#   - Argo Workflows Installation
#   - Ingress for workflows.upandrunning.local
# =============================================================================

set -e

NAMESPACE="${NAMESPACE:-argo-workflows}"
WORKFLOWS_HOST="${WORKFLOWS_HOST:-workflows.upandrunning.local}"
ARGO_VERSION="${ARGO_VERSION:-v3.5.4}"

echo "================================================"
echo "  Argo Workflows Setup"
echo "================================================"
echo "  Namespace: ${NAMESPACE}"
echo "  Version:   ${ARGO_VERSION}"
echo "  Host:      ${WORKFLOWS_HOST}"
echo "================================================"

# -----------------------------------------------------------------------------
# Check Cluster
# -----------------------------------------------------------------------------
echo ""
echo "[1/6] Checking cluster connection..."
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Cannot connect to Kubernetes cluster. Ensure your cluster is running."
    exit 1
fi
echo "✅ Cluster connected"

# -----------------------------------------------------------------------------
# Install Argo Workflows
# -----------------------------------------------------------------------------
echo ""
echo "[2/6] Downloading and patching Argo Workflows manifest..."
TEMP_MANIFEST=$(mktemp)
curl -sL "https://github.com/argoproj/argo-workflows/releases/download/${ARGO_VERSION}/install.yaml" > "${TEMP_MANIFEST}"

echo "Creating namespace '${NAMESPACE}'..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "Patching manifest to use namespace '${NAMESPACE}'..."
# Replace 'namespace: argo' with the custom namespace
# This handles the case where resources have a hardcoded namespace
sed -i '' "s/namespace: argo/namespace: ${NAMESPACE}/g" "${TEMP_MANIFEST}"

echo "Applying patched manifest..."
kubectl apply -n "${NAMESPACE}" -f "${TEMP_MANIFEST}"
rm -f "${TEMP_MANIFEST}"

echo "Granting permissions to the 'default' service account in '${NAMESPACE}'..."
# This avoids 'forbidden' errors when running simple workflows without specifying a service account
kubectl create rolebinding default-admin --clusterrole=argo-cluster-role --serviceaccount="${NAMESPACE}:default" -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "Waiting for Argo Workflows pods to be ready..."
kubectl wait --for=condition=Ready pods --all -n "${NAMESPACE}" --timeout=300s
echo "✅ Argo Workflows installed"

# -----------------------------------------------------------------------------
# Configure Auth Mode
# -----------------------------------------------------------------------------
echo ""
echo "[3/6] Configuring Server Auth Mode to 'server'..."
# This allows access without providing a token, suitable for local dev
kubectl patch deployment argo-server -n "${NAMESPACE}" --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": ["server", "--auth-mode=server"]}]'

echo "Restarting argo-server to apply changes..."
kubectl rollout restart deployment argo-server -n "${NAMESPACE}"
kubectl rollout status deployment argo-server -n "${NAMESPACE}" --timeout=120s
echo "✅ Auth mode configured"

# -----------------------------------------------------------------------------
# Create Ingress
# -----------------------------------------------------------------------------
echo ""
echo "[4/6] Creating Ingress for Argo Workflows UI..."
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argo-workflows-ingress
  namespace: ${NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  rules:
  - host: ${WORKFLOWS_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argo-server
            port:
              number: 2746
EOF
echo "✅ Ingress created"

# -----------------------------------------------------------------------------
# Update /etc/hosts
# -----------------------------------------------------------------------------
echo ""
echo "[5/6] Checking /etc/hosts..."
if grep -q "${WORKFLOWS_HOST}" /etc/hosts; then
    echo "✅ ${WORKFLOWS_HOST} already in /etc/hosts"
else
    echo "Adding ${WORKFLOWS_HOST} to /etc/hosts (requires sudo)..."
    echo "127.0.0.1 ${WORKFLOWS_HOST}" | sudo tee -a /etc/hosts
    echo "✅ Added to /etc/hosts"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "================================================"
echo "  ✅ Setup Complete!"
echo "================================================"
echo ""
echo "  URL: https://${WORKFLOWS_HOST}"
echo ""
echo "  Note: The UI is configured with --auth-mode=server"
echo "        for easy local access."
echo ""
echo "================================================"
