#!/bin/bash

# Script to create sealed secrets from plain text values
# Usage: ./create-sealed-secrets.sh

set -e

# Check if kubeseal is installed
if ! command -v kubeseal &> /dev/null; then
    echo "kubeseal is not installed. Please install it first:"
    echo "https://github.com/bitnami-labs/sealed-secrets/releases"
    exit 1
fi

# Function to create sealed secret
create_sealed_secret() {
    local name=$1
    local namespace=$2
    local key=$3
    local value=$4
    
    echo "Creating sealed secret: $name in namespace: $namespace"
    
    kubectl create secret generic $name \
        --from-literal=$key="$value" \
        --dry-run=client -o yaml | \
    kubeseal -o yaml --controller-namespace sealed-secrets --controller-name sealed-secrets-controller
}

echo "=== Creating Sealed Secrets ==="
echo "Note: Replace the placeholder values with your actual secrets"
echo ""

echo "# N8N Database Credentials"
create_sealed_secret "n8n-db-secret" "n8n-dev" "username" "REPLACE_WITH_DB_USERNAME"
echo "---"
create_sealed_secret "n8n-db-secret" "n8n-dev" "password" "REPLACE_WITH_DB_PASSWORD"
echo "---"

echo "# N8N Encryption Key"
create_sealed_secret "n8n-encryption" "n8n-dev" "key" "REPLACE_WITH_ENCRYPTION_KEY"
echo "---"

echo "# Database Storage Secrets"
create_sealed_secret "n8n-db-storage" "cnpg-dev" "blob-sas" "REPLACE_WITH_BLOB_SAS"
echo "---"
create_sealed_secret "n8n-db-storage" "cnpg-dev" "container-name" "REPLACE_WITH_CONTAINER_NAME"
echo "---"
create_sealed_secret "n8n-db-storage" "cnpg-dev" "destination-path" "REPLACE_WITH_DESTINATION_PATH"
echo "---"

echo "# Database Credentials for CNPG"
create_sealed_secret "n8n-db-creds" "cnpg-dev" "username" "REPLACE_WITH_DB_USERNAME"
echo "---"
create_sealed_secret "n8n-db-creds" "cnpg-dev" "password" "REPLACE_WITH_DB_PASSWORD"

echo ""
echo "=== Instructions ==="
echo "1. Replace placeholder values with actual secrets"
echo "2. Update the sealed-secrets.yaml files with the generated encrypted data"
echo "3. Commit and push to trigger ArgoCD sync"