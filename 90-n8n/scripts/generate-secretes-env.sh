
#!/usr/bin/env bash
# cd $HOME/workplace/train/devops-labs/90-n8n
set -euo pipefail

# Usage: ./generate-secrets.sh dev|qa
ENV="${1:-dev}"
if [[ "$ENV" != "dev" && "$ENV" != "qa" ]]; then
  echo "Usage: $0 dev|qa"
  exit 1
fi

# Controller coordinates (must match your installation)
CONTROLLER_NAME="sealed-secrets"
CONTROLLER_NAMESPACE="argocd"

# Namespaces per environment (adjust as needed)
APP_NS="n8n-${ENV}"
DB_NS="cnpg-${ENV}"

# Paths in the repo (adjust to your layout)
APPS_SEALED_PATH="./apps/n8n/overlays/${ENV}/sealed-secrets.yaml"
DB_SEALED_PATH="./databases/n8n/overlays/${ENV}/sealed-secrets.yaml"

# Generate secrets
DB_PASSWORD="$(openssl rand -base64 32)"
ENCRYPTION_KEY="$(openssl rand -hex 32)"

echo "=== Generating Sealed Secrets for ENV=${ENV} ==="

# Ensure output dirs exist
mkdir -p "$(dirname "${APPS_SEALED_PATH}")" "$(dirname "${DB_SEALED_PATH}")"

# 1) App secrets (username/password & encryption key)
kubectl create secret generic n8n-db-secret \
  --from-literal=username=n8n \
  --from-literal=password="${DB_PASSWORD}" \
  --namespace="${APP_NS}" --dry-run=client -o yaml | \
  kubeseal \
    --controller-name="${CONTROLLER_NAME}" \
    --controller-namespace="${CONTROLLER_NAMESPACE}" \
    -o yaml > "${APPS_SEALED_PATH}"

echo "---" >> "${APPS_SEALED_PATH}"

kubectl create secret generic n8n-encryption \
  --from-literal=key="${ENCRYPTION_KEY}" \
  --namespace="${APP_NS}" --dry-run=client -o yaml | \
  kubeseal \
    --controller-name="${CONTROLLER_NAME}" \
    --controller-namespace="${CONTROLLER_NAMESPACE}" \
    -o yaml >> "${APPS_SEALED_PATH}"

# 2) Database credentials (same password)
kubectl create secret generic n8n-db-creds \
  --from-literal=username=n8n \
  --from-literal=password="${DB_PASSWORD}" \
  --namespace="${DB_NS}" --dry-run=client -o yaml | \
  kubeseal \
    --controller-name="${CONTROLLER_NAME}" \
    --controller-namespace="${CONTROLLER_NAMESPACE}" \
    -o yaml > "${DB_SEALED_PATH}"

echo "Done! SealedSecret manifests:"
echo "  ${APPS_SEALED_PATH}"
echo "  ${DB_SEALED_PATH}"

# Print generated values (capture securely if needed)
echo "DB_PASSWORD: ${DB_PASSWORD}"
echo "ENCRYPTION_KEY: ${ENCRYPTION_KEY}"
