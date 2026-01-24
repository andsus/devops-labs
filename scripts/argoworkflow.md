argo submit -n argo --serviceaccount argo-workflow --watch https://raw.githubusercontent.com/argoproj/argo-workflows/master/examples/hello-world.yaml


argo submit --serviceaccount argo-workflow --watch dag-workflow.yaml -n argo-workflows

argo submit --watch exit-handler-workflow.yaml  -n argo-workflows

argo submit --watch parameters-workflow.yaml  -n argo-workflows