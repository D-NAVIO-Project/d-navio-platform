{{/* Partner id: the release is named <partner>-infra by the deploy workflow. */}}
{{- define "infra.partner" -}}
{{- trimSuffix "-infra" .Release.Name -}}
{{- end }}

{{/*
A password generated on first install and kept stable afterwards: Postgres
reads it only when the data volume is first initialised.
*/}}
{{- define "infra.password" -}}
{{- $name := printf "%s-secrets" (include "infra.partner" .) -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $name -}}
{{- if and $existing $existing.data (hasKey $existing.data "postgres-password") -}}
{{- index $existing.data "postgres-password" | b64dec -}}
{{- else -}}
{{- randAlphaNum 32 -}}
{{- end -}}
{{- end }}
