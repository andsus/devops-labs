# Prefect on Kubernetes — Self-Hosted HA Setup

Prefect v3 deployed on Kubernetes via ArgoCD, using the App of Apps pattern.
Stack: Prefect Server (HA) + Kubernetes Worker + PostgreSQL + Redis + NGINX Ingress.

---

## Architecture

```
                        ┌─────────────────────────────────────────┐
                        │              ArgoCD                      │
                        │                                          │
                        │   prefect (App of Apps)                  │
                        │   ├── prefect-secrets                    │
                        │   ├── prefect-postgresql                 │
                        │   ├── prefect-redis                      │
                        │   ├── prefect-server                     │
                        │   └── prefect-worker                     │
                        └─────────────────────────────────────────┘

                        ┌─────────────────────────────────────────┐
                        │           prefect namespace              │
                        │                                          │
  Browser / CLI  ──────►│  NGINX Ingress                           │
  prefect.upandrunning  │  prefect.upandrunning.local              │
  .local                │         │                                │
                        │         ▼                                │
                        │  prefect-server (2 replicas, API only)   │
                        │  prefect-background (2 replicas)         │
                        │         │                                │
                        │    ┌────┴────┐                           │
                        │    ▼         ▼                           │
                        │ PostgreSQL  Redis                         │
                        │                                          │
                        │  prefect-worker                          │
                        │  (polls API → submits K8s Jobs)          │
                        └─────────────────────────────────────────┘
```

### Component roles

| Component | Purpose |
|-----------|---------|
| `prefect-server` | Serves the UI and REST API (`--no-services` flag, API only) |
| `prefect-background` | Runs scheduler, automation triggers, loop services |
| `prefect-postgresql` | Persistent state store for flows, deployments, runs |
| `prefect-redis` | Event messaging broker, causal ordering, docket coordination |
| `prefect-worker` | Polls API for scheduled runs, submits them as Kubernetes Jobs |

---

## Repository layout

```
100-prefect/
├── argocd/
│   ├── prefect-app-of-apps.yaml        # Parent — bootstraps everything
│   ├── prefect-secrets-application.yaml
│   ├── postgresql-application.yaml
│   ├── redis-application.yaml
│   ├── prefect-server-application.yaml
│   └── prefect-worker-application.yaml
├── secrets/
│   ├── prefect-db-sealedsecret.yaml    # SealedSecret with DB credentials
│   └── secret-template.yaml
└── flows/
    ├── hello_flow.py                   # Sample flow (local reference)
    └── hello-flow-job.yaml             # K8s Job to run the sample flow
```

---

## Prerequisites

- Kubernetes cluster (tested on k3d)
- ArgoCD installed in `argocd` namespace
- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) controller in `kube-system`
- NGINX Ingress controller
- `kubeseal` CLI installed locally
- DNS or `/etc/hosts` entry: `<ingress-ip> prefect.upandrunning.local`

---

## Secret setup

The `prefect-db-secret` SealedSecret holds all database credentials and must exist
before the server and postgresql apps sync. It contains four keys:

| Key | Used by |
|-----|---------|
| `postgres-password` | PostgreSQL superuser (Bitnami chart) |
| `password` | `prefect` user password (Bitnami chart) |
| `connection-url` | Prefect server env (`PREFECT_API_DATABASE_CONNECTION_URL`) |
| `connection-string` | Prefect helm chart internal secret reference |

Both `connection-url` and `connection-string` must use the `postgresql+asyncpg://` scheme
(Prefect requires asyncpg, not psycopg2):

```
postgresql+asyncpg://prefect:<password>@prefect-postgresql.prefect.svc.cluster.local:5432/prefect
```

To re-create the SealedSecret from scratch:

```bash
kubectl create secret generic prefect-db-secret \
  --namespace prefect \
  --from-literal=postgres-password='<superuser-password>' \
  --from-literal=password='<prefect-user-password>' \
  --from-literal=connection-url='postgresql+asyncpg://prefect:<password>@prefect-postgresql.prefect.svc.cluster.local:5432/prefect' \
  --from-literal=connection-string='postgresql+asyncpg://prefect:<password>@prefect-postgresql.prefect.svc.cluster.local:5432/prefect' \
  --dry-run=client -o yaml | \
kubeseal --controller-namespace kube-system --controller-name sealed-secrets \
  --format yaml > 100-prefect/secrets/prefect-db-sealedsecret.yaml
```

---

## Bootstrap (fresh install)

Apply only the parent app — ArgoCD does the rest:

```bash
kubectl apply -f 100-prefect/argocd/prefect-app-of-apps.yaml
```

ArgoCD will create and sync all child apps in the `argocd` namespace, which in turn
deploy all resources into the `prefect` namespace.

### First-time DB migration

The helm chart runs a `post-install` migration job automatically. If it fails
(e.g. the DB wasn't ready), run it manually:

```bash
kubectl run prefect-migrate --restart=Never --namespace prefect \
  --image=prefecthq/prefect:3-latest \
  --env="PREFECT_API_DATABASE_CONNECTION_URL=postgresql+asyncpg://prefect:<password>@prefect-postgresql.prefect.svc.cluster.local:5432/prefect" \
  -- prefect server database upgrade -y

# Clean up after success
kubectl delete pod prefect-migrate -n prefect
```

### Verify all pods are running

```bash
kubectl get pods -n prefect
# Expected:
# prefect-postgresql-0              1/1   Running
# prefect-redis-master-0            1/1   Running
# prefect-server-<hash>             1/1   Running   (x2)
# prefect-worker-<hash>             1/1   Running
```

---

## Helm chart gotchas (lessons learned)

### 1. `secret.create: false` + `secret.name` are both required

The `prefect-server` chart always mounts a secret named `{release}-postgresql-connection`
in the Deployment even when `secret.create: false`. Setting `secret.name: prefect-db-secret`
redirects that mount to the existing secret. Without this the pods get
`CreateContainerConfigError: secret "prefect-server-postgresql-connection" not found`.

```yaml
secret:
  create: false
  name: prefect-db-secret
```

### 2. The chart expects key `connection-string`, not `connection-url`

The Deployment template hardcodes `.data["connection-string"]` from the secret. The
`connection-url` key is only used by the custom `env` block. Both keys must exist in
the SealedSecret.

### 3. `postgresql+asyncpg://` scheme is required

Prefect uses SQLAlchemy async engine which requires `asyncpg`. Using a plain
`postgresql://` URL causes `ModuleNotFoundError: No module named 'psycopg2'` at startup.

### 4. Internal service hostnames

Bitnami helm charts prefix the release name to the service name. The correct hostnames are:

| Wrong | Correct |
|-------|---------|
| `postgresql.prefect.svc.cluster.local` | `prefect-postgresql.prefect.svc.cluster.local` |
| `redis-master.prefect.svc.cluster.local` | `prefect-redis-master.prefect.svc.cluster.local` |

### 5. ArgoCD caches manifest generation errors

After fixing a helm values error, ArgoCD may keep showing the old error from cache.
Clear it and reapply the Application manifest:

```bash
kubectl patch application prefect-server -n argocd --type=json \
  -p='[{"op":"remove","path":"/status/conditions"}]'
kubectl annotate application prefect-server -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
# If still stale, reapply the manifest:
kubectl apply -f 100-prefect/argocd/prefect-server-application.yaml
```

### 6. `configuration-snippet` annotation is blocked

The NGINX ingress controller runs with `allow-snippet-annotations: false` by default
(security hardening). The `nginx.ingress.kubernetes.io/configuration-snippet` annotation
causes the admission webhook to reject the Ingress. WebSocket support does not need it —
NGINX handles `Upgrade`/`Connection` headers automatically with `proxy-http-version: 1.1`.

---

## Prefect server configuration

The server runs in HA mode split across two Deployments:

- `prefect-server` — API + UI only (`--no-services` flag)
- `prefect-background` — scheduler, automation engine, loop services

Both connect to the same PostgreSQL and Redis. Key environment variables:

| Variable | Value |
|----------|-------|
| `PREFECT_API_DATABASE_CONNECTION_URL` | From `prefect-db-secret` key `connection-url` |
| `PREFECT_API_DATABASE_MIGRATE_ON_START` | `false` (migration job handles it) |
| `PREFECT_MESSAGING_BROKER` | `prefect_redis.messaging` |
| `PREFECT_MESSAGING_CACHE` | `prefect_redis.messaging` |
| `PREFECT_SERVER_EVENTS_CAUSAL_ORDERING` | `prefect_redis.ordering` |
| `PREFECT_SERVER_CONCURRENCY_LEASE_STORAGE` | `prefect_redis.lease_storage` |
| `PREFECT_REDIS_MESSAGING_HOST` | `prefect-redis-master.prefect.svc.cluster.local` |
| `PREFECT_SERVER_DOCKET_URL` | `redis://prefect-redis-master.prefect.svc.cluster.local:6379/1` |
| `PREFECT_UI_API_URL` | `http://prefect.upandrunning.local/api` |

---

## Worker configuration

The worker uses a `kubernetes` work pool named `kube-work-pool`. It polls the server
via internal cluster DNS (not the ingress) and submits flow runs as Kubernetes Jobs.

```
apiUrl: http://prefect-server.prefect.svc.cluster.local:4200/api
```

The worker's ServiceAccount has RBAC permissions to create/watch/delete Jobs in the
`prefect` namespace (managed by `rbac.create: true` in the helm chart).

---

## Running a flow

A sample 3-task flow is provided in `flows/`. Run it as a Kubernetes Job:

```bash
kubectl apply -f 100-prefect/flows/hello-flow-job.yaml

# Stream logs
kubectl logs -n prefect -l job-name=hello-flow -f

# Re-run
kubectl delete job hello-flow -n prefect
kubectl apply -f 100-prefect/flows/hello-flow-job.yaml
```

The flow runs directly against the API (not via the worker). To submit through the
worker and work pool, deploy the flow with `prefect deploy` pointing at `kube-work-pool`.

---

## Accessing the UI

```
http://prefect.upandrunning.local
```

Ensure your `/etc/hosts` or local DNS maps this hostname to the ingress controller IP:

```bash
kubectl get ingress prefect-server -n prefect
# Use the ADDRESS column value
echo "<ADDRESS>  prefect.upandrunning.local" | sudo tee -a /etc/hosts
```

---

## Teardown

Deleting the parent app cascades to all child apps and their cluster resources:

```bash
kubectl delete application prefect -n argocd
```
