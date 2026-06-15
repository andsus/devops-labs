# Prowler on Kubernetes - Self-Hosted Setup

Prowler deployed on Kubernetes via ArgoCD, using the App of Apps pattern.
Stack: Prowler API + UI + Worker + MCP + PostgreSQL + Valkey + Neo4j + NGINX Ingress.

---

## Architecture

```
                        +-----------------------------------------+
                        |                ArgoCD                   |
                        |                                         |
                        |   prowler-stack (App of Apps)           |
                        |   +-- prowler-secrets                   |
                        |   +-- prowler-postgresql                |
                        |   +-- prowler-valkey                    |
                        |   +-- prowler                           |
                        +-----------------------------------------+

                        +-----------------------------------------+
                        |            prowler namespace             |
                        |                                         |
 Browser        ------>|  NGINX Ingress                           |
 prowler.upandrunning  |  prowler.upandrunning.local              |
 .local                |         |                                |
                        |         v                                |
                        |  prowler-ui                              |
                        |         |                                |
                        |         v                                |
                        |  prowler-api                             |
                        |    |       |       |                     |
                        |    v       v       v                     |
                        | PostgreSQL Valkey  Neo4j                 |
                        |                                         |
                        |  prowler-worker                          |
                        |  prowler-worker-beat                     |
                        |  prowler-mcp                             |
                        +-----------------------------------------+
```

### Component roles

| Component | Purpose |
|-----------|---------|
| `prowler-api` | Django API, database migrations, health endpoint |
| `prowler-ui` | Web UI served behind the ingress |
| `prowler-worker` | Celery worker for scans, reports, integrations, compliance, and attack paths |
| `prowler-worker-beat` | Celery beat scheduler; waits for the API before starting |
| `prowler-mcp` | MCP server for Prowler integrations |
| `prowler-postgresql` | Bitnami PostgreSQL chart, persistent relational store |
| `prowler-valkey` | Bitnami Valkey chart, Redis-compatible broker/cache |
| `prowler-neo4j` | Neo4j StatefulSet for attack path data |

---

## Repository layout

```
110-prowler/
+-- argocd/
|   +-- prowler-app-of-apps.yaml          # Parent app - bootstraps everything
|   +-- prowler-secrets-application.yaml
|   +-- prowler-postgresql-application.yaml
|   +-- prowler-valkey-application.yaml
|   +-- prowler-application.yaml
+-- manifests/
|   +-- namespace.yaml
|   +-- configmap.yaml                    # Shared app configuration
|   +-- api-deployment.yaml
|   +-- worker-deployment.yaml
|   +-- ui-deployment.yaml
|   +-- mcp-deployment.yaml
|   +-- neo4j-statefulset.yaml
|   +-- pvc.yaml
|   +-- services.yaml
|   +-- ingress.yaml
+-- secrets/
|   +-- prowler-sealedsecret.yaml         # SealedSecret with DB, Neo4j, and Django secrets
+-- README.md
```

---

## Prerequisites

- Kubernetes cluster (tested on k3d)
- ArgoCD installed in the `argocd` namespace
- Sealed Secrets controller in `kube-system`
- `kubeseal` CLI installed locally
- NGINX Ingress controller
- DNS or `/etc/hosts` entry: `<ingress-ip> prowler.upandrunning.local`

---

## Secret setup

The `prowler-secret` SealedSecret is shared by the Bitnami PostgreSQL chart and the
Prowler workloads. It must exist before PostgreSQL and the app workloads sync.

| Key | Used by |
|-----|---------|
| `POSTGRES_ADMIN_USER` | Prowler API migration/admin connection. Must be `postgres` for the Bitnami chart superuser |
| `POSTGRES_ADMIN_PASSWORD` | PostgreSQL superuser password |
| `POSTGRES_USER` | Prowler application database user |
| `POSTGRES_PASSWORD` | Prowler application database password |
| `POSTGRES_DB` | Prowler application database name |
| `NEO4J_USER` | Neo4j username |
| `NEO4J_PASSWORD` | Neo4j password |
| `AUTH_SECRET` | UI/auth secret |
| `DJANGO_SECRETS_ENCRYPTION_KEY` | Django secrets encryption key |
| `DJANGO_TOKEN_SIGNING_KEY` | Django private signing key |
| `DJANGO_TOKEN_VERIFYING_KEY` | Django public verification key |

To re-create the SealedSecret from scratch:

```bash
kubectl create secret generic prowler-secret \
  --namespace prowler \
  --from-literal=POSTGRES_ADMIN_USER=postgres \
  --from-literal=POSTGRES_ADMIN_PASSWORD='<postgres-admin-password>' \
  --from-literal=POSTGRES_USER=prowler \
  --from-literal=POSTGRES_PASSWORD='<prowler-db-password>' \
  --from-literal=POSTGRES_DB=prowler_db \
  --from-literal=NEO4J_USER=neo4j \
  --from-literal=NEO4J_PASSWORD='<neo4j-password>' \
  --from-literal=AUTH_SECRET='<auth-secret>' \
  --from-literal=DJANGO_SECRETS_ENCRYPTION_KEY='<django-encryption-key>' \
  --from-literal=DJANGO_TOKEN_SIGNING_KEY="$(cat /path/to/private.pem)" \
  --from-literal=DJANGO_TOKEN_VERIFYING_KEY="$(openssl rsa -in /path/to/private.pem -pubout 2>/dev/null)" \
  --dry-run=client -o yaml | \
kubeseal --controller-namespace kube-system --controller-name sealed-secrets \
  --format yaml > 110-prowler/secrets/prowler-sealedsecret.yaml
```

---

## Bootstrap (fresh install)

Apply only the parent app. ArgoCD creates and syncs the child apps:

```bash
kubectl apply -f 110-prowler/argocd/prowler-app-of-apps.yaml
```

ArgoCD deploys the child Applications in the `argocd` namespace and the workloads in
the `prowler` namespace.

### Verify all pods are running

```bash
kubectl get pods -n prowler
# Expected:
# prowler-postgresql-0                  1/1   Running
# prowler-valkey-redis-master-0         1/1   Running
# prowler-neo4j-0                       1/1   Running
# prowler-api-<hash>                    1/1   Running
# prowler-ui-<hash>                     1/1   Running
# prowler-worker-<hash>                 1/1   Running
# prowler-worker-beat-<hash>            1/1   Running
# prowler-mcp-<hash>                    1/1   Running
```

Check ArgoCD status:

```bash
kubectl get applications -n argocd
```

---

## PostgreSQL chart configuration

The Bitnami PostgreSQL chart is configured to use `prowler-secret` directly:

```yaml
auth:
  username: prowler
  database: prowler_db
  existingSecret: prowler-secret
  secretKeys:
    adminPasswordKey: POSTGRES_ADMIN_PASSWORD
    userPasswordKey: POSTGRES_PASSWORD
```

The chart creates:

- `postgres` superuser
- `prowler` application user
- `prowler_db` database

Prowler migrations use the admin connection, so `POSTGRES_ADMIN_USER` must match the
actual Bitnami superuser: `postgres`. Do not set it to a custom user such as
`prowler_admin` unless that database role is explicitly created.

---

## Prowler API startup tuning

The API has a slow cold-start path:

1. Apply migrations.
2. Manage database partitions.
3. Start Gunicorn.
4. Import Django URL modules on the first health request.
5. Warm compliance caches and attack-path related modules.

The container may log `Worker was sent SIGKILL! Perhaps out of memory?` when Gunicorn
workers time out during cold start. In this lab, Kubernetes memory usage was well below
the memory limit; the fix was probe and Gunicorn tuning, not only adding memory.

Important settings:

| Setting | Why |
|---------|-----|
| `GUNICORN_CMD_ARGS=--timeout 180 --graceful-timeout 180` | Gunicorn honors this env var even though `DJANGO_WORKER_TIMEOUT` is not read by the bundled `guniconf.py` |
| `startupProbe` | Prevents liveness from killing the API while migrations and first imports run |
| Probe `Host: prowler-api` header | Avoids Django `ALLOWED_HOSTS` rejecting kubelet pod-IP probes with HTTP 400 |
| Longer probe timeouts | Allows the first `/health/live` request to finish its lazy imports |
| Higher API memory request/limit | Leaves enough room for scans and compliance/attack path imports |

---

## Operational checks

Check API health through the service:

```bash
kubectl run prowler-api-check --rm -i --restart=Never \
  --namespace prowler \
  --image=curlimages/curl:latest \
  -- curl -H 'Host: prowler-api' -fsS http://prowler-api:8080/health/live
```

Check API logs:

```bash
kubectl logs -n prowler deployment/prowler-api --tail=100
```

Check current resource usage:

```bash
kubectl top pods -n prowler
```

Restart app workloads after config or secret changes:

```bash
kubectl rollout restart deployment/prowler-api deployment/prowler-worker deployment/prowler-worker-beat -n prowler
```

---

## Gotchas (lessons learned)

### 1. Bitnami PostgreSQL does not create arbitrary admin users

The chart creates the configured app user and the `postgres` superuser. If Prowler is
configured with `POSTGRES_ADMIN_USER=prowler_admin`, migrations fail because that role
does not exist. Use `POSTGRES_ADMIN_USER=postgres`.

### 2. `auth.secretKeys` must match custom secret keys

Without `auth.secretKeys.adminPasswordKey` and `auth.secretKeys.userPasswordKey`, the
Bitnami chart expects its default keys such as `postgresql-postgres-password` and
`postgresql-password`. This setup maps the chart to `POSTGRES_ADMIN_PASSWORD` and
`POSTGRES_PASSWORD`.

### 3. Secret changes require pod restarts

The API and workers consume `prowler-secret` through `envFrom`. Kubernetes does not
update environment variables in already-running containers. Restart app Deployments
after a SealedSecret change is reconciled.

### 4. ArgoCD self-heal overwrites direct kubectl patches

The `prowler` Application syncs from Git and has `selfHeal: true`. Direct `kubectl`
patches are useful for live debugging, but durable fixes must be committed and pushed
to the ArgoCD source branch.

### 5. Kubelet probes need an allowed Host header

Django rejects unknown hosts. Kubelet HTTP probes often arrive with a pod-IP Host
header, causing HTTP 400. The probes set `Host: prowler-api`, which is already in
`DJANGO_ALLOWED_HOSTS`.

### 6. UI auth routes must stay on the UI service

The UI uses NextAuth under `/api/auth/*`. The ingress must route `/api/auth` to
`prowler-ui` before the broader `/api` rule sends API traffic to `prowler-api`.
If `/api/auth/session` reaches Django, login pages show auth/session errors and the
API logs show `GET /api/auth/session` returning 404.

### 7. Worker-beat waits for API

`prowler-worker-beat` has an init container that polls `http://prowler-api:8080/health/live`.
If the API is not Ready, beat remains in `Init:0/1`.
