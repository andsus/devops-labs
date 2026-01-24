#!/bin/bash
# =============================================================================
# Argo Workflows Git Test execution script
# =============================================================================

set -e

NAMESPACE="${NAMESPACE:-argo-workflows}"
WORKFLOW_FILE="$(dirname "$0")/../examples/git-test-workflow.yaml"

echo "================================================"
echo "  Argo Workflows Git Test"
echo "================================================"

# Submit the workflow
echo "Submitting workflow..."
WF_NAME=$(kubectl create -f "${WORKFLOW_FILE}" -o name)
echo "✅ Workflow created: ${WF_NAME}"

# Wait for completion
echo "Waiting for workflow to complete..."
kubectl wait --for=condition=Completed "${WF_NAME}" -n "${NAMESPACE}" --timeout=300s

# Show logs
echo ""
echo "--- Workflow Logs ---"
kubectl logs -n "${NAMESPACE}" -l workflows.argoproj.io/workflow="${WF_NAME#workflow.argoproj.io/}" --tail=-1
echo "---------------------"

echo ""
echo "✅ Test complete. You can also view results at https://workflows.upandrunning.local"
