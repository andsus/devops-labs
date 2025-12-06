# n8n Quick Start Guide

## Prerequisites
✓ ArgoCD installed
✓ Sealed Secrets controller deployed  
✓ kubeseal CLI installed

## Deploy n8n (5 steps)

### 1. Install CNPG Operator
```bash
kubectl apply -f argocd/cnpg-operator-application.yaml
kubectl wait --for=condition=available --timeout=300s deployment/cnpg-operator-cloudnative-pg -n cnpg-system
```

### 2. Generate Secrets
```bash
./scripts/generate-secrets.sh
git add . && git commit -m "Add sealed secrets" && git push
```

### 3. Deploy Database
```bash
kubectl apply -f argocd/db-applicationset.yaml
# Wait 2-3 minutes
kubectl get cluster -n cnpg-dev
```

### 4. Deploy n8n App
```bash
kubectl apply -f argocd/applicationset.yaml
kubectl get pods -n n8n-dev
```

### 5. Access n8n
```bash
kubectl port-forward -n n8n-dev svc/n8n 5678:80
# Open: http://localhost:5678
```

## Verify Deployment
```bash
# Database (should show 3 instances ready)
kubectl get cluster -n cnpg-dev

# n8n (should show 1/1 running)
kubectl get pods -n n8n-dev
```

## Troubleshooting
```bash
# Check CNPG operator
kubectl get pods -n cnpg-system

# Check database logs
kubectl logs -n cnpg-dev n8n-db-cnpg-v1-1

# Check n8n logs
kubectl logs -n n8n-dev -l app=n8n
```
