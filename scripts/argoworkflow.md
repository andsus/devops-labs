argo submit -n argoworkflows --serviceaccount argo-workflow --watch https://raw.githubusercontent.com/argoproj/argo-workflows/master/examples/hello-world.yaml


argo submit --serviceaccount argo-workflow --watch dag-workflow.yaml -n argoworkflows

argo submit --watch exit-handler-workflow.yaml  -n argoworkflows

argo submit --watch parameters-workflow.yaml  -n argoworkflows
