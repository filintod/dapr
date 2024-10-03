{{/* Provides the helm hook annotation for CRDs that should be installed first */}}
{{ define "dapr.hook-annotations-crds" }}
"helm.sh/hook": pre-install,pre-upgrade
"helm.sh/hook-weight": "-5"
helm.sh/resource-policy: {{default "keep" .Values.global.daprCRDs.resourcePolicy }}
{{ end }}

{{/* Provides the helm hook annotation for the dapr-operator deployment that should be installed after CRDs */}}
{{ define "dapr.hook-annotations-dapr-control-plane" }}
"helm.sh/hook": post-install,post-upgrade
"helm.sh/hook-weight": "5"
{{ end }}

{{/* Provides the helm hook annotation for the crd resources (e.g. configurations) */}}
{{ define "dapr.hook-annotations-crd-resource" }}
"helm.sh/hook": post-install,post-upgrade
"helm.sh/hook-weight": "0"
{{ end }}
