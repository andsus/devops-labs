#!/bin/bash
# =============================================================================
# ArgoCD Setup with kind + Podman Desktop (macOS Silicon)
# =============================================================================
# Prerequisites:
#   - Podman Desktop installed and podman machine running
#   - brew install kind kubectl
# 
# Usage: ./setup-argocd-kind-podman.sh
# =============================================================================

set -e

CLUSTER_NAME="${CLUSTER_NAME:-argocd}"
ARGOCD_HOST="${ARGOCD_HOST:-argocd.upandrunning.local}"

# Use Podman as the provider
export KIND_EXPERIMENTAL_PROVIDER=podman

echo "================================================"
echo "  ArgoCD Setup with kind + Podman"
echo "================================================"

# Check prerequisites
echo ""
echo "[1/9] Checking prerequisites..."
if ! command -v podman &> /dev/null; then
    echo "❌ Podman is not installed. Install with: brew install --cask podman-desktop"
    exit 1
fi

if ! podman machine info &> /dev/null 2>&1; then
    echo "❌ Podman machine is not running."
    echo "   Run: podman machine init && podman machine start"
    exit 1
fi

if ! command -v kind &> /dev/null; then
    echo "❌ kind is not installed. Install with: brew install kind"
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is not installed. Install with: brew install kubectl"
    exit 1
fi

echo "✅ All prerequisites met"
echo "   Using KIND_EXPERIMENTAL_PROVIDER=podman"

# Create kind config
echo ""
echo "[2/9] Creating kind cluster configuration..."
KIND_CONFIG=$(mktemp)
cat > "${KIND_CONFIG}" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF
echo "✅ Configuration created"

# Create kind cluster
echo ""
echo "[3/9] Creating kind cluster '${CLUSTER_NAME}' with Podman..."
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "⚠️  Cluster '${CLUSTER_NAME}' already exists. Skipping creation."
else
    kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
    echo "✅ Cluster created"
fi

rm -f "${KIND_CONFIG}"

# Wait for cluster to be ready
echo ""
echo "[4/9] Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=60s
echo "✅ Cluster is ready"

# Install NGINX Ingress Controller (kind-specific manifest)
echo ""
echo "[5/9] Installing NGINX Ingress Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

echo "Waiting for ingress controller to be ready..."
kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=120s
echo "✅ Ingress controller is ready"

# Install ArgoCD
echo ""
echo "[6/9] Installing ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for ArgoCD pods to be ready (this may take a few minutes)..."
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s
echo "✅ ArgoCD is installed"

# Create Ingress for ArgoCD
echo ""
echo "[7/9] Creating ArgoCD Ingress..."
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  rules:
  - host: ${ARGOCD_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 443
EOF
echo "✅ Ingress created"

# Check /etc/hosts
echo ""
echo "[8/9] Checking /etc/hosts..."
if grep -q "${ARGOCD_HOST}" /etc/hosts; then
    echo "✅ ${ARGOCD_HOST} already in /etc/hosts"
else
    echo "Adding ${ARGOCD_HOST} to /etc/hosts (requires sudo)..."
    echo "127.0.0.1 ${ARGOCD_HOST}" | sudo tee -a /etc/hosts
    echo "✅ Added to /etc/hosts"
fi

# Get admin password
echo ""
echo "[9/9] Getting ArgoCD admin password..."
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

echo ""
echo "================================================"
echo "  ✅ Setup Complete!"
echo "================================================"
echo ""
echo "  URL:      https://${ARGOCD_HOST}"
echo "  Username: admin"
echo "  Password: ${ARGOCD_PASSWORD}"
echo ""
echo "  Note: Accept the self-signed certificate warning in your browser."
echo ""
echo "================================================"
echo ""
echo "Useful commands:"
echo "  KIND_EXPERIMENTAL_PROVIDER=podman kind get clusters"
echo "  KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name ${CLUSTER_NAME}"
echo ""
