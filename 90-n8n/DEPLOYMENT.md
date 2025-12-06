# n8n Deployment Steps

## Prerequisites
- ArgoCD installed ✓
- Sealed Secrets controller deployed ✓
- kubeseal CLI installed

## 1. Generate Sealed Secrets

```bash
cd /Users/SUSANAX5/workplace/train/devops-labs/90-n8n

# Edit values in script, then run:
./scripts/generate-secrets.sh
```

## 2. Deploy Database

```bash
kubectl apply -f argocd/db-applicationset.yaml
```

## 3. Deploy n8n Application

```bash
kubectl apply -f argocd/applicationset.yaml
```

## 4. Verify Deployment

```bash
# Check database
kubectl get cluster -n cnpg-dev
kubectl get pods -n cnpg-dev

# Check n8n
kubectl get pods -n n8n-dev
kubectl get svc -n n8n-dev
```
