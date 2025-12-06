# Secrets Configuration Guide

## Required Secrets

### 1. n8n-db-secret (namespace: n8n-dev)
Used by n8n app to connect to PostgreSQL database.

- **username**: `n8n` (must match database owner)
- **password**: Choose a strong password (e.g., `$(openssl rand -base64 32)`)

### 2. n8n-encryption (namespace: n8n-dev)
Used by n8n to encrypt credentials stored in the database.

- **key**: 64-character hex string (e.g., `$(openssl rand -hex 32)`)

### 3. n8n-db-creds (namespace: cnpg-dev)
Used by CloudNativePG to create the database and user.

- **username**: `n8n` (must match n8n-db-secret username)
- **password**: Same as n8n-db-secret password

### 4. n8n-db-storage (namespace: cnpg-dev)
Used by CloudNativePG for Azure Blob Storage backups.

- **container-name**: Azure storage container name (e.g., `n8n-backups`)
- **blob-sas**: Azure Blob SAS token with read/write permissions
- **destination-path**: Not used in current config (can be empty or `/`)

## Generate Secrets

```bash
# Generate strong password
DB_PASSWORD=$(openssl rand -base64 32)

# Generate encryption key
ENCRYPTION_KEY=$(openssl rand -hex 32)

echo "DB_PASSWORD: $DB_PASSWORD"
echo "ENCRYPTION_KEY: $ENCRYPTION_KEY"
```

## Azure Blob Storage Setup (Optional)

If you want backups, create Azure storage:

```bash
# Create storage account and container
az storage account create --name n8nbackups --resource-group mygroup
az storage container create --name n8n-backups --account-name n8nbackups

# Generate SAS token (valid for 1 year)
az storage container generate-sas \
  --account-name n8nbackups \
  --name n8n-backups \
  --permissions acdlrw \
  --expiry $(date -u -d "1 year" '+%Y-%m-%dT%H:%MZ')
```

## Without Azure Backups

If you don't need backups, remove the backup section from `databases/n8n/base/database.yaml`:

```yaml
# Remove this entire section:
  backup:
    barmanObjectStore:
      ...
```

And don't create the `n8n-db-storage` secret.
