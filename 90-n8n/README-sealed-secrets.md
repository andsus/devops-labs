# Migration from External Secrets to Sealed Secrets

This document describes the migration from External Secrets Operator (ESO) to Bitnami Sealed Secrets.

## Changes Made

### 1. Infrastructure
- **Removed**: `infrastructure/external-secrets/`
- **Added**: `infrastructure/sealed-secrets/` with controller deployment

### 2. Secret Management
- **Replaced**: `ExternalSecret` manifests with `SealedSecret` manifests
- **Files changed**:
  - `apps/n8n/overlays/dev/secrets.yaml` → `sealed-secrets.yaml`
  - `databases/n8n/overlays/dev/secrets.yaml` → `sealed-secrets.yaml`

### 3. ArgoCD Applications
- **Replaced**: `external-secrets-application.yaml` with `sealed-secrets-application.yaml`

## Setup Instructions

### 1. Install kubeseal CLI
```bash
# macOS
brew install kubeseal

# Linux
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/kubeseal-0.24.0-linux-amd64.tar.gz
tar -xvzf kubeseal-0.24.0-linux-amd64.tar.gz
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
```

### 2. Deploy Sealed Secrets Controller
```bash
# Apply the ArgoCD application
kubectl apply -f argocd/sealed-secrets-application.yaml

# Or deploy directly
kubectl apply -k infrastructure/sealed-secrets/
```

### 3. Generate Sealed Secrets
```bash
# Use the provided script
./scripts/create-sealed-secrets.sh

# Or manually create individual secrets
echo -n "your-secret-value" | kubectl create secret generic secret-name \
  --dry-run=client --from-file=key=/dev/stdin -o yaml | \
  kubeseal -o yaml --controller-namespace sealed-secrets
```

### 4. Update Sealed Secret Manifests
Replace the placeholder encrypted data in:
- `apps/n8n/overlays/dev/sealed-secrets.yaml`
- `databases/n8n/overlays/dev/sealed-secrets.yaml`

### 5. Deploy Applications
```bash
# Sync ArgoCD applications
argocd app sync sealed-secrets-infra
argocd app sync n8n-dev
argocd app sync n8n-db-dev
```

## Key Differences

| External Secrets | Sealed Secrets |
|------------------|----------------|
| Fetches from external stores | Encrypts secrets at rest |
| Runtime secret retrieval | Build-time secret encryption |
| Requires cloud credentials | Uses cluster public key |
| Dynamic secret rotation | Manual secret updates |

## Security Notes

- Sealed secrets are encrypted with the cluster's public key
- Only the sealed-secrets controller can decrypt them
- Safe to store in Git repositories
- Secrets are namespace-scoped by default

## Troubleshooting

### Controller not starting
```bash
kubectl logs -n sealed-secrets deployment/sealed-secrets-controller
```

### Secret not being created
```bash
kubectl describe sealedsecret <secret-name> -n <namespace>
```

### Re-encrypt existing secrets
```bash
# Get the controller's public key
kubeseal --fetch-cert > public.pem

# Encrypt with specific certificate
kubeseal --cert public.pem -o yaml < secret.yaml > sealed-secret.yaml
```