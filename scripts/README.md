# ArgoCD Local Kubernetes Setup Scripts

Scripts for setting up ArgoCD with NGINX Ingress on local Kubernetes (macOS Silicon).

## Options

| Option | Script | Container Runtime |
|--------|--------|-------------------|
| **k3d + Docker** | `setup-argocd-k3d.sh` | Docker Desktop |
| **kind + Podman** | `setup-argocd-kind-podman.sh` | Podman Desktop |

## Quick Start

### Option 1: k3d + Docker (Recommended)

**Prerequisites:**
```bash
brew install --cask docker    # Install Docker Desktop
brew install k3d kubectl
```

**Setup:**
```bash
chmod +x scripts/*.sh
./scripts/setup-argocd-k3d.sh
```

**Access:** https://argocd.upandrunning.local

---

### Option 2: kind + Podman

**Prerequisites:**
```bash
brew install --cask podman-desktop
podman machine init
podman machine start
brew install kind kubectl
```

**Setup:**
```bash
chmod +x scripts/*.sh
./scripts/setup-argocd-kind-podman.sh
```

**Access:** https://argocd.upandrunning.local

### Argo Workflows

**Setup:**
```bash
./scripts/setup-argoworkflows.sh
```

**Access:** https://workflows.upandrunning.local (Auth mode: `server`)

---

## Sealed Secrets Usage Guide

### 1. Install `kubeseal` CLI
```bash
brew install kubeseal
```

### 2. Create a Sealed Secret
Sealed Secrets allows you to safely commit secrets to Git. Only the controller in the cluster can decrypt them.

**Steps:**
1. Create a regular Kubernetes secret file (locally only!):
   ```bash
   kubectl create secret generic my-secret \
     --from-literal=password=supersecret \
     --dry-run=client -o yaml > my-secret.yaml
   ```

2. "Seal" the secret using `kubeseal`:
   ```bash
   kubeseal --format=yaml \
     --controller-name=sealed-secrets \
     --controller-namespace=kube-system \
     < my-secret.yaml > my-sealed-secret.yaml
   ```
   *Note: Since we installed using the Bitnami Helm chart, the service name is `sealed-secrets` instead of the default `sealed-secrets-controller`. `my-sealed-secret.yaml` is now safe to commit to Git.*

3. Apply the Sealed Secret to your cluster:
   ```bash
   kubectl apply -f my-sealed-secret.yaml
   ```

4. Verify the controller decrypted it back into a Secret:
   ```bash
   kubectl get secret my-secret
   ```

### 3. Delete a Secret
To fully remove a secret, you must delete both the `SealedSecret` and the actual `Secret`.

```bash
# Delete the SealedSecret (this removes the 'source' of the secret)
kubectl delete sealedsecret my-secret

# Delete the actual Secret (the controller might have already deleted it, but verify)
kubectl delete secret my-secret
```

---

## After Laptop Restart

### k3d clusters persist! Just restart them:

```bash
# Start Docker Desktop first, then:
./scripts/start-argocd-k3d.sh

# Or manually:
k3d cluster start argocd
```

### kind + Podman:

```bash
# Start Podman machine first:
podman machine start

# Then check if cluster exists:
KIND_EXPERIMENTAL_PROVIDER=podman kind get clusters
```

> **Note:** kind clusters also persist in Podman, but may need recreation if the Podman machine was recreated.

---

## Cluster Management

### k3d Commands
```bash
k3d cluster list                    # List clusters
k3d cluster stop argocd             # Stop (preserves data)
k3d cluster start argocd            # Start
k3d cluster delete argocd           # Delete (removes data)
```

### kind + Podman Commands
```bash
export KIND_EXPERIMENTAL_PROVIDER=podman
kind get clusters                   # List clusters
kind delete cluster --name argocd   # Delete cluster
```

---

## Troubleshooting

### Slow Workflow Pod Initialization (10+ minutes)

**Symptom:** Argo Workflow pods stuck in `PodInitializing` for a long time.

**Cause:** Calico authorization errors after cluster has been running 24+ hours.

**Fix:**
```bash
./scripts/fix-calico-auth.sh
```

Or manually:
```bash
kubectl rollout restart daemonset/calico-node -n calico-system
```

---

## Teardown

```bash
# k3d
./scripts/teardown-argocd-k3d.sh

# kind + Podman
./scripts/teardown-argocd-kind-podman.sh

# Clean /etc/hosts manually:
sudo sed -i '' '/argocd.upandrunning.local/d' /etc/hosts
```

---

## ArgoCD Credentials

- **URL:** https://argocd.upandrunning.local
- **Username:** admin
- **Password:** 
  ```bash
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
  ```

---

## Comparison

| Feature | k3d + Docker | kind + Podman |
|---------|--------------|---------------|
| Tunnel required | No ✅ | No ✅ |
| Startup speed | Very Fast ✅ | Fast |
| Stability | Stable ✅ | Experimental |
| License | Docker Desktop license | Open source ✅ |
| Persistence | Survives restart ✅ | Survives restart ✅ |

--

================================================
  ✅ Setup Complete!
================================================

  CLUSTER INFO
  ────────────────────────────────────────────
  Name:     calico-argocd
  Nodes:    1 control-plane + 3 workers
  CNI:      Calico v3.27.0

  ARGOCD ACCESS
  ────────────────────────────────────────────
  URL:      https://argocd.upandrunning.local
  Username: admin
  Password: Nk7zfeoRZdXtFmgk

  Note: Accept the self-signed certificate warning

================================================

Useful commands:
  kubectl get nodes                    # Check nodes
  kubectl get pods -n calico-system    # Check Calico
  kubectl get pods -n argocd           # Check ArgoCD
  kubectl get ingress -n argocd        # Check Ingress

  k3d cluster stop calico-argocd     # Stop cluster
  k3d cluster start calico-argocd    # Start cluster
  k3d cluster delete calico-argocd   # Delete cluster
