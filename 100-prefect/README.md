# 100 — Prefect Server (Self-Hosted HA)

Self-hosted [Prefect](https://www.prefect.io/) workflow orchestration platform, deployed on
k3d + Calico + ArgoCD via the official [prefect-helm](https://github.com/PrefectHQ/prefect-helm) charts.

## Architecture

```
prefect namespace
├── postgresql          (Bitnami chart)   — persistent state
├── redis               (Bitnami chart)   — event messaging + Docket coordination
├── prefect-server x2  (API replicas)     — UI + API, --no-services
├── prefect-background x2 (bg services)  — scheduler, triggers, loop services
└── prefect-worker x1  (K8s worker)      — submits flows as K8s Jobs
```

**Ingress**: `http://prefect.upandrunning.local` → NGINX → `prefect-server:4200`

## Prerequisites

- k3d cluster running (see `../scripts/setup-argocd-k3d-calico.sh`)
- ArgoCD running at `https://argocd.upandrunning.local`
- `kubectl` and `argocd` CLIs available

### 1. Login to ArgoCD CLI

```bash
export argoPass=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
export argoURL=argocd.upandrunning.local

argocd login --insecure --grpc-web $argoURL --username admin --password $argoPass
```

### 2. Register the Git repository via SSH

```bash
argocd repo add git@github.com:andsus/devops-labs.git \
  --ssh-private-key-path ~/.ssh/id_ed25519
```

Expected output:
```
Repository 'git@github.com:andsus/devops-labs.git' added
```

> **Note**: If you get a `knownhosts: key is unknown` error, add GitHub's SSH host key first:
> ```bash
> ssh-keyscan github.com | argocd cert add-ssh --batch
> ```

### 3. Commit and push the manifests

Make sure to add `.gitignore` so your raw secrets are never committed:

```bash
git add .gitignore 100-prefect/
git commit -m "feat: add Prefect Server HA deployment with Sealed Secrets"
git push origin main
```

## Deployment

Apply the ArgoCD Application manifests in dependency order. Each `kubectl apply` registers
the app with ArgoCD; ArgoCD then syncs and deploys the workloads from the Git/Helm repos.

### Step 1 — /etc/hosts

```bash
echo "127.0.0.1  prefect.upandrunning.local" | sudo tee -a /etc/hosts
```

### Step 2 — Deploy Prefect Secrets (SealedSecret)

```bash
kubectl apply -f 100-prefect/argocd/prefect-secrets-application.yaml

# Watch ArgoCD sync it to create the decypted secret
argocd app get prefect-secrets --watch
```

Wait until `STATUS: Synced` and `HEALTH: Healthy`. This creates `prefect-db-secret` inside the `prefect` namespace.

### Step 3 — Deploy PostgreSQL (backend database)

```bash
kubectl apply -f 100-prefect/argocd/postgresql-application.yaml

# Watch ArgoCD sync it
argocd app get prefect-postgresql --watch
```

Wait until `STATUS: Synced` and `HEALTH: Healthy` before continuing.

### Step 4 — Deploy Redis (event messaging + coordination)

```bash
kubectl apply -f 100-prefect/argocd/redis-application.yaml

argocd app get prefect-redis --watch
```

Wait until `STATUS: Synced` and `HEALTH: Healthy`.

### Step 5 — Deploy Prefect Server (HA)

```bash
kubectl apply -f 100-prefect/argocd/prefect-server-application.yaml

# Follow the sync — migration Job runs first, then API + background pods start
argocd app get prefect-server --watch
```

### Step 6 — Deploy Prefect Worker

```bash
kubectl apply -f 100-prefect/argocd/prefect-worker-application.yaml

argocd app get prefect-worker --watch
```

### One-liner (apply all at once)

```bash
kubectl apply \
  -f 100-prefect/argocd/prefect-secrets-application.yaml \
  -f 100-prefect/argocd/postgresql-application.yaml \
  -f 100-prefect/argocd/redis-application.yaml \
  -f 100-prefect/argocd/prefect-server-application.yaml \
  -f 100-prefect/argocd/prefect-worker-application.yaml
```

## Verify

```bash
# All ArgoCD apps healthy
argocd app list | grep prefect

# All pods running in the prefect namespace
kubectl get pods -n prefect

# Health endpoint
curl http://prefect.upandrunning.local/api/health
# Expected: {"status":"healthy"}
```

## Running Your First Flow

```bash
# Point the Prefect CLI at your self-hosted server
export PREFECT_API_URL=http://prefect.upandrunning.local/api

# Create the Kubernetes work pool (first time only)
prefect work-pool create kube-work-pool --type kubernetes

# Run a test flow
python - <<'EOF'
import prefect

@prefect.flow
def hello():
    print("Hello from Prefect on k3d!")

if __name__ == "__main__":
    hello.serve(name="hello-deployment")
EOF
```

## HA Configuration Notes

| Component | Setting | Value |
|-----------|---------|-------|
| API replicas | `server.replicaCount` | 2 |
| Background service replicas | `backgroundService.replicaCount` | 2 |
| DB migrations | `PREFECT_API_DATABASE_MIGRATE_ON_START` | `false` (migration Job handles it) |
| Messaging broker | `PREFECT_MESSAGING_BROKER` | `prefect_redis.messaging` |
| Docket backend | `PREFECT_SERVER_DOCKET_URL` | Redis DB 1 |
| Messaging | `PREFECT_REDIS_MESSAGING_DB` | Redis DB 0 |

## Teardown

```bash
kubectl delete -f argocd/prefect-worker-application.yaml
kubectl delete -f argocd/prefect-server-application.yaml
kubectl delete -f argocd/redis-application.yaml
kubectl delete -f argocd/postgresql-application.yaml
kubectl delete namespace prefect
```

## Production Hardening

- [ ] Replace plaintext passwords with **SealedSecrets** (see `../90-n8n/README-sealed-secrets.md`)
- [ ] Pin `targetRevision` to a specific chart version (not `"*"`)
- [ ] Enable Redis auth (`auth.enabled: true`)
- [ ] Add PostgreSQL read replicas (`readReplicas.replicaCount: 1`)
- [ ] Configure Prometheus + Grafana for [Prefect monitoring](https://docs.prefect.io/v3/advanced/self-hosted#monitoring)
