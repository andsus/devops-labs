# n8n Deployment Steps

## Prerequisites
- ArgoCD installed ✓
- Sealed Secrets controller deployed ✓
- kubeseal CLI installed

## 1. Install CloudNativePG Operator

```bash
cd /Users/SUSANAX5/workplace/train/devops-labs/90-n8n

# Install CNPG CRDs first
kubectl apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.24/releases/cnpg-1.24.0.yaml

# Deploy via ArgoCD
kubectl apply -f argocd/cnpg-operator-application.yaml

# Wait for operator
kubectl wait --for=condition=available --timeout=300s deployment/cnpg-operator-cloudnative-pg -n cnpg-system
```

## 2. Generate Sealed Secrets

```bash
./scripts/generate-secrets.sh

# Commit and push
git add .
git commit -m "Add sealed secrets for n8n"
git push
```

## 3. Deploy Database

```bash
kubectl apply -f argocd/db-applicationset.yaml

# Check deployment
kubectl get applications -n argocd | grep n8n-db
kubectl get cluster -n cnpg-dev
kubectl get pods -n cnpg-dev
```

## 4. Deploy n8n Application

```bash
kubectl apply -f argocd/applicationset.yaml

# Check deployment
kubectl get pods -n n8n-dev
kubectl get svc -n n8n-dev
```

## 5. Access n8n

```bash
# Port forward
kubectl port-forward -n n8n-dev svc/n8n 5678:80

# Open browser: http://localhost:5678
```
