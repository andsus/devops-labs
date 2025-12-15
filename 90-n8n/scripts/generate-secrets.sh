#!/bin/bash
set -e

# Generate secrets
DB_PASSWORD=$(openssl rand -base64 32)
ENCRYPTION_KEY=$(openssl rand -hex 32)
CONTROLLER_NAME='sealed-secrets' # sealed-secrets-controller
CONTROLLER_NAMESPACE='argocd'
echo "=== Generating n8n Sealed Secrets ==="

# n8n app secrets
kubectl create secret generic n8n-db-secret \
  --from-literal=username=n8n \
  --from-literal=password="$DB_PASSWORD" \
  --namespace=n8n-dev --dry-run=client -o yaml | \
  kubeseal --controller-name="$CONTROLLER_NAME" --controller-namespace="$CONTROLLER_NAMESPACE" -o yaml > apps/n8n/overlays/dev/sealed-secrets.yaml

echo "---" >> apps/n8n/overlays/dev/sealed-secrets.yaml

kubectl create secret generic n8n-encryption \
  --from-literal=key="$ENCRYPTION_KEY" \
  --namespace=n8n-dev --dry-run=client -o yaml | \
  kubeseal --controller-name="$CONTROLLER_NAME" --controller-namespace="$CONTROLLER_NAMESPACE" -o yaml >> apps/n8n/overlays/dev/sealed-secrets.yaml

# Database secrets (same password)
kubectl create secret generic n8n-db-creds \
  --from-literal=username=n8n \
  --from-literal=password="$DB_PASSWORD" \
  --namespace=cnpg-dev --dry-run=client -o yaml | \
  kubeseal --controller-name="$CONTROLLER_NAME" --controller-namespace="$CONTROLLER_NAMESPACE" -o yaml > databases/n8n/overlays/dev/sealed-secrets.yaml

echo "Done! Secrets generated."
echo "DB_PASSWORD: $DB_PASSWORD"
echo "ENCRYPTION_KEY: $ENCRYPTION_KEY"
