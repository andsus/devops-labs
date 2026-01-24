#!/bin/bash
# =============================================================================
# ArgoCD Setup with k3d + Calico CNI + NGINX Ingress (macOS Silicon)
# =============================================================================
# Creates:
#   - k3d cluster: 1 control-plane + 3 workers, default CNI disabled
#   - Bootstrap namespace: kube-system (Calico installed here)
#   - Calico CNI
#   - NGINX Ingress Controller
#   - ArgoCD with ingress at argocd.upandrunning.local
# =============================================================================

set -e

CLUSTER_NAME="${CLUSTER_NAME:-calico-argocd}"
ARGOCD_HOST="${ARGOCD_HOST:-argocd.upandrunning.local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALICO_VERSION="${CALICO_VERSION:-v3.27.0}"

echo "================================================"
echo "  k3d + Calico + ArgoCD Setup"
echo "================================================"
echo "  Cluster: ${CLUSTER_NAME}"
echo "  Nodes:   1 control-plane + 3 workers"
echo "  CNI:     Calico ${CALICO_VERSION}"
echo "================================================"

# -----------------------------------------------------------------------------
# Prerequisites Check
# -----------------------------------------------------------------------------
echo ""
echo "[1/10] Checking prerequisites..."

if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Install with: brew install --cask docker"
    exit 1
fi

if ! docker info &> /dev/null; then
    echo "❌ Docker is not running. Please start Docker Desktop."
    exit 1
fi

if ! command -v k3d &> /dev/null; then
    echo "❌ k3d is not installed. Install with: brew install k3d"
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is not installed. Install with: brew install kubectl"
    exit 1
fi

echo "✅ All prerequisites met"

# Check Docker resource allocation
echo ""
echo "Checking Docker Desktop resources..."
DOCKER_MEM_BYTES=$(docker info --format '{{.MemTotal}}')
DOCKER_MEM_GB=$(echo "scale=1; $DOCKER_MEM_BYTES / 1024 / 1024 / 1024" | bc)
DOCKER_CPUS=$(docker info --format '{{.NCPU}}')

echo "  Memory: ${DOCKER_MEM_GB}GB"
echo "  CPUs:   ${DOCKER_CPUS}"

if (( $(echo "$DOCKER_MEM_GB < 4" | bc -l) )); then
    echo ""
    echo "⚠️  WARNING: Docker has ${DOCKER_MEM_GB}GB memory."
    echo "   Recommend at least 4GB for stable Calico operation."
    echo "   Increase in: Docker Desktop → Settings → Resources → Memory"
    echo ""
    read -p "Continue anyway? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Setup cancelled. Please increase Docker resources and try again."
        exit 1
    fi
fi

if [ "$DOCKER_CPUS" -lt 2 ]; then
    echo "⚠️  WARNING: Docker has ${DOCKER_CPUS} CPU(s). Recommend at least 2 CPUs."
fi

# -----------------------------------------------------------------------------
# Create k3d Cluster (CNI disabled)
# -----------------------------------------------------------------------------
echo ""
echo "[2/10] Creating k3d cluster with CNI disabled..."

if k3d cluster list 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
    echo "⚠️  Cluster '${CLUSTER_NAME}' already exists."
    read -p "Delete and recreate? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        k3d cluster delete "${CLUSTER_NAME}"
    else
        echo "Using existing cluster..."
    fi
fi

if ! k3d cluster list 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
    # Generate config with custom cluster name
    K3D_CONFIG=$(mktemp)
    cat > "${K3D_CONFIG}" <<EOF
apiVersion: k3d.io/v1alpha5
kind: Simple
metadata:
  name: ${CLUSTER_NAME}
servers: 1
agents: 3
ports:
  - port: 80:80
    nodeFilters:
      - loadbalancer
  - port: 443:443
    nodeFilters:
      - loadbalancer
options:
  k3s:
    extraArgs:
      - arg: --flannel-backend=none
        nodeFilters:
          - server:*
      - arg: --disable-network-policy
        nodeFilters:
          - server:*
      - arg: --disable=traefik
        nodeFilters:
          - server:*
EOF
    k3d cluster create --config "${K3D_CONFIG}"
    rm -f "${K3D_CONFIG}"
    echo "✅ Cluster created with CNI disabled"
fi

# Wait for nodes (they will be NotReady until CNI is installed)
echo ""
echo "Waiting for nodes to appear (will show NotReady until Calico is installed)..."
sleep 5
kubectl get nodes

# -----------------------------------------------------------------------------
# Install Calico CNI
# -----------------------------------------------------------------------------
echo ""
echo "[3/10] Installing Calico CNI ${CALICO_VERSION}..."

# Install Calico operator
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml 2>/dev/null || true

# Wait for operator to be ready
echo "Waiting for Tigera operator..."
kubectl wait --for=condition=Available deployment/tigera-operator \
    -n tigera-operator --timeout=120s 2>/dev/null || sleep 30

# Install Calico custom resources
# Using CIDR that matches k3s default
cat <<EOF | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: 10.42.0.0/16
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
  # Add component resource limits for stability
  componentResources:
  - componentName: Node
    resourceRequirements:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 300m
        memory: 512Mi
  - componentName: Typha
    resourceRequirements:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 256Mi
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF

echo "Waiting for Calico to be ready (this may take 2-3 minutes)..."
sleep 30

# Wait for Calico pods
kubectl wait --for=condition=Ready pods -l k8s-app=calico-node \
    -n calico-system --timeout=300s 2>/dev/null || true

# Verify nodes are Ready
echo ""
echo "Waiting for all nodes to become Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

echo "✅ Calico CNI installed"
kubectl get nodes

# Wait for Calico API Server to be ready
echo ""
echo "Waiting for Calico API Server to be ready..."
kubectl wait --for=condition=Available deployment/calico-apiserver \
    -n calico-apiserver --timeout=180s 2>/dev/null || echo "  (Calico API server deployment not found or not yet ready)"

echo "✅ Calico components ready"

# -----------------------------------------------------------------------------
# Install NGINX Ingress Controller
# -----------------------------------------------------------------------------
echo ""
echo "[4/10] Installing NGINX Ingress Controller..."

kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml

echo "Waiting for ingress-nginx namespace and deployment to be created..."
sleep 10

# Wait for the deployment to exist first
kubectl wait --namespace ingress-nginx \
    --for=condition=Available deployment/ingress-nginx-controller \
    --timeout=180s

echo "Waiting for ingress controller pod to be ready..."
kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=180s

echo "✅ NGINX Ingress Controller installed"

# -----------------------------------------------------------------------------
# Install ArgoCD
# -----------------------------------------------------------------------------
echo ""
echo "[5/10] Creating ArgoCD namespace..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "[6/10] Installing ArgoCD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for ArgoCD pods to be ready (this may take 2-3 minutes)..."
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

echo "✅ ArgoCD installed"

# Delete ArgoCD server network policy (blocks ingress traffic with Calico)
echo ""
echo "Removing ArgoCD server network policy for ingress access..."
kubectl delete networkpolicy argocd-server-network-policy -n argocd 2>/dev/null || true

# Configure ArgoCD to run in insecure mode (let nginx handle TLS)
echo "Configuring ArgoCD for insecure mode (TLS terminated at ingress)..."
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge -p '{"data":{"server.insecure":"true"}}'
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd --timeout=120s

# -----------------------------------------------------------------------------
# Create ArgoCD Ingress
# -----------------------------------------------------------------------------
echo ""
echo "[7/10] Creating ArgoCD Ingress..."

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
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
              number: 80
EOF

echo "✅ ArgoCD Ingress created"

# -----------------------------------------------------------------------------
# Install Sealed Secrets
# -----------------------------------------------------------------------------
echo ""
echo "[8/10] Deploying Sealed Secrets as ArgoCD Application..."

cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sealed-secrets
  namespace: argocd
spec:
  project: default
  source:
    chart: sealed-secrets
    repoURL: https://bitnami-labs.github.io/sealed-secrets
    targetRevision: 2.15.0
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

echo "✅ Sealed Secrets application created"

# -----------------------------------------------------------------------------
# Update /etc/hosts
# -----------------------------------------------------------------------------
echo ""
echo "[9/10] Checking /etc/hosts..."

if grep -q "${ARGOCD_HOST}" /etc/hosts; then
    echo "✅ ${ARGOCD_HOST} already in /etc/hosts"
else
    echo "Adding ${ARGOCD_HOST} to /etc/hosts (requires sudo)..."
    echo "127.0.0.1 ${ARGOCD_HOST}" | sudo tee -a /etc/hosts
    echo "✅ Added to /etc/hosts"
fi

# -----------------------------------------------------------------------------
# Get ArgoCD Password
# -----------------------------------------------------------------------------
echo ""
echo "[10/10] Getting ArgoCD admin password..."
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "================================================"
echo "  ✅ Setup Complete!"
echo "================================================"
echo ""
echo "  CLUSTER INFO"
echo "  ────────────────────────────────────────────"
echo "  Name:     ${CLUSTER_NAME}"
echo "  Nodes:    1 control-plane + 3 workers"
echo "  CNI:      Calico ${CALICO_VERSION}"
echo ""
echo "  ARGOCD ACCESS"
echo "  ────────────────────────────────────────────"
echo "  URL:      https://${ARGOCD_HOST}"
echo "  Username: admin"
echo "  Password: ${ARGOCD_PASSWORD}"
echo ""
echo "  Note: Accept the self-signed certificate warning"
echo ""
echo "================================================"
echo ""
echo "Useful commands:"
echo "  kubectl get nodes                    # Check nodes"
echo "  kubectl get pods -n calico-system    # Check Calico"
echo "  kubectl get pods -n argocd           # Check ArgoCD"
echo "  kubectl get ingress -n argocd        # Check Ingress"
echo ""
echo "  k3d cluster stop ${CLUSTER_NAME}     # Stop cluster"
echo "  k3d cluster start ${CLUSTER_NAME}    # Start cluster"
echo "  k3d cluster delete ${CLUSTER_NAME}   # Delete cluster"
echo ""
