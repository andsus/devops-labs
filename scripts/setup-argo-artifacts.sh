#!/bin/bash
# =============================================================================
# Setup Minio for Argo Workflows Artifact Storage
# =============================================================================

set -e

NAMESPACE="${NAMESPACE:-argo-workflows}"
MINIO_ACCESS_KEY="admin"
MINIO_SECRET_KEY="password"
BUCKET_NAME="my-bucket"

echo "================================================"
echo "  Argo Workflows Artifact Storage Setup (Minio)"
echo "================================================"

# 1. Create Minio Secret
echo "[1/4] Creating Minio credentials secret..."
kubectl create secret generic argo-artifacts \
  --from-literal=accesskey="${MINIO_ACCESS_KEY}" \
  --from-literal=secretkey="${MINIO_SECRET_KEY}" \
  -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# 2. Deploy Minio (Single-node, non-persistent for local development)
echo "[2/4] Deploying Minio to ${NAMESPACE}..."
cat <<EOF | kubectl apply -n "${NAMESPACE}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
spec:
  selector:
    matchLabels:
      app: minio
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: minio/minio:latest
        args:
        - server
        - /data
        - --console-address
        - ":9001"
        env:
        - name: MINIO_ROOT_USER
          value: "${MINIO_ACCESS_KEY}"
        - name: MINIO_ROOT_PASSWORD
          value: "${MINIO_SECRET_KEY}"
        ports:
        - containerPort: 9000
          name: api
        - containerPort: 9001
          name: console
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: minio
spec:
  type: ClusterIP
  ports:
    - port: 9000
      targetPort: 9000
      name: api
    - port: 9001
      targetPort: 9001
      name: console
  selector:
    app: minio
EOF

# 3. Create Minio Bucket (using a temporary pod if needed, or wait and use mc)
echo "Waiting for Minio to be ready..."
kubectl wait --for=condition=Available deployment/minio -n "${NAMESPACE}" --timeout=300s

# Create bucket via a simple pod
echo "Creating bucket '${BUCKET_NAME}'..."
kubectl run create-bucket --image=minio/mc -n "${NAMESPACE}" --restart=Never --rm -i \
  --overrides='{"spec": {"containers": [{"name": "create-bucket", "image": "minio/mc", "command": ["sh", "-c", "mc alias set minio http://minio:9000 admin password && mc mb minio/my-bucket || true"]}]}}' -- /dev/null

# 4. Configure Argo Workflow Controller
echo "[4/4] Configuring Argo Workflow Controller..."
kubectl patch configmap workflow-controller-configmap -n "${NAMESPACE}" --type merge -p "
data:
  artifactRepository: |
    s3:
      bucket: ${BUCKET_NAME}
      endpoint: minio:9000
      insecure: true
      accessKeySecret:
        name: argo-artifacts
        key: accesskey
      secretKeySecret:
        name: argo-artifacts
        key: secretkey
"

# Restart workflow controller to apply changes
echo "Restarting workflow controller..."
kubectl rollout restart deployment/workflow-controller -n "${NAMESPACE}"
kubectl rollout status deployment/workflow-controller -n "${NAMESPACE}"

echo ""
echo "✅ Minio artifact storage configured!"
echo "Bucket: ${BUCKET_NAME}"
echo "Endpoint: minio.${NAMESPACE}.svc:9000"
echo ""
echo "You can now run your artifact-based workflows."
