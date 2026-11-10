{{/*
Standard labels applied to every resource.
*/}}
{{- define "dnavio-platform.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels used by Deployments and Services.
Intentionally minimal — adding labels here is a breaking change for running Deployments.
*/}}
{{- define "dnavio-platform.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
A credential that is generated once and then stays stable across upgrades.
Resolution order: explicit override (e.g. injected by CI) -> the value already
stored in the live Secret -> a new random value (first install only).
Stability matters because the datastores and Keycloak clients only take their
credentials at initialisation; a value that changed on every deploy would lock
consumers out. Under `helm template` (no cluster) a random value is rendered.
Usage: include "dnavio-platform.stableSecret" (list $ "secret-name" "key" $override)
*/}}
{{- define "dnavio-platform.stableSecret" -}}
{{- $ctx := index . 0 -}}
{{- $name := index . 1 -}}
{{- $key := index . 2 -}}
{{- $override := index . 3 -}}
{{- if $override -}}
{{- $override -}}
{{- else -}}
{{- $existing := lookup "v1" "Secret" $ctx.Release.Namespace $name -}}
{{- if and $existing $existing.data (hasKey $existing.data $key) -}}
{{- index $existing.data $key | b64dec -}}
{{- else -}}
{{- randAlphaNum 32 -}}
{{- end -}}
{{- end -}}
{{- end }}
