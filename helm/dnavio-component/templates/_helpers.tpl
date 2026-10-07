{{/*
Resource name for a component: <partner>-<component>.
Usage: include "dnavio-component.fullname" (dict "root" $ "c" $component)
*/}}
{{- define "dnavio-component.fullname" -}}
{{- printf "%s-%s" .root.Values.partner .c.name -}}
{{- end }}

{{/*
Labels applied to every resource of a component.
*/}}
{{- define "dnavio-component.labels" -}}
helm.sh/chart: {{ .root.Chart.Name }}-{{ .root.Chart.Version }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/part-of: d-navio
dnavio/partner: {{ .root.Values.partner }}
{{ include "dnavio-component.selectorLabels" . }}
{{- end }}

{{/*
Selector labels. The name label differs from the platform chart's, so a
partner selector can never match platform pods.
*/}}
{{- define "dnavio-component.selectorLabels" -}}
app.kubernetes.io/name: dnavio-component
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .c.name }}
{{- end }}

{{/*
Name of the Secret behind a secretEnv alias.
*/}}
{{- define "dnavio-component.secretName" -}}
{{- if eq .alias "partner" -}}
{{- printf "%s-secrets" .root.Values.partner -}}
{{- else -}}
{{- index .root.Values.platform.secrets .alias -}}
{{- end -}}
{{- end }}

{{/*
Validation. Every rule a partner values file must satisfy is checked here, so a
non-conforming file fails at deploy time with a clear message instead of
producing a broken or unsafe workload.
*/}}
{{- define "dnavio-component.validate" -}}
{{- $root := . -}}
{{- $dns := "^[a-z]([-a-z0-9]*[a-z0-9])?$" -}}
{{- $partner := .Values.partner | default "" -}}
{{- if not (regexMatch $dns $partner) -}}
{{- fail "partner: required, lowercase letters, digits and hyphens (e.g. t42)" -}}
{{- end -}}
{{- if gt (len $partner) 20 -}}
{{- fail (printf "partner: %q is longer than 20 characters" $partner) -}}
{{- end -}}
{{- if not .Values.image.tag -}}
{{- fail "image.tag: required — the deploy workflow sets it to the git SHA of the build" -}}
{{- end -}}
{{- if not .Values.components -}}
{{- fail "components: at least one component is required" -}}
{{- end -}}
{{- /* Platform services: components use the platform's instead of their own.
       Datastores: partners run their own, but with their own chart — this
       chart runs stateless services only (no volumes). */ -}}
{{- $platformImages := list "kafka" "cp-kafka" "cp-server" "redpanda" "zookeeper" "keycloak" "minio" -}}
{{- $datastoreImages := list "postgres" "postgresql" "mongo" "mongodb" "mysql" "mariadb" "redis" -}}
{{- $credentialLike := "(?i)(password|passwd|secret|token|api_?key|private_?key)" -}}
{{- $seen := dict -}}
{{- range $c := .Values.components -}}
{{- $name := $c.name | default "" -}}
{{- if not (regexMatch $dns $name) -}}
{{- fail (printf "components: name %q must be lowercase letters, digits and hyphens" $name) -}}
{{- end -}}
{{- if hasKey $seen $name -}}
{{- fail (printf "components: name %q is used more than once" $name) -}}
{{- end -}}
{{- $_ := set $seen $name true -}}
{{- $full := printf "%s-%s" $partner $name -}}
{{- if gt (len $full) 63 -}}
{{- fail (printf "components: %q exceeds 63 characters" $full) -}}
{{- end -}}
{{- $image := $c.image | default "" -}}
{{- if not $image -}}
{{- fail (printf "components.%s: image is required" $name) -}}
{{- end -}}
{{- if or (regexMatch ":[^/]*$" $image) (contains "@" $image) -}}
{{- fail (printf "components.%s: image %q must not carry a tag or digest — the tag comes from the build" $name $image) -}}
{{- end -}}
{{- $base := last (splitList "/" $image) -}}
{{- if has $base $platformImages -}}
{{- fail (printf "components.%s: image %q is a platform service — use the platform's broker, Keycloak and MinIO instead of deploying your own" $name $image) -}}
{{- end -}}
{{- if has $base $datastoreImages -}}
{{- fail (printf "components.%s: image %q is a datastore — run it with your own chart (this chart has no volumes) and pass its connection string through Secret %s-secrets" $name $image $partner) -}}
{{- end -}}
{{- if not (regexMatch "^[0-9]+(Mi|Gi)$" (toString ($c.memory | default ""))) -}}
{{- fail (printf "components.%s: memory is required, e.g. 64Mi (used as request and limit)" $name) -}}
{{- end -}}
{{- if $c.port -}}
{{- $port := int $c.port -}}
{{- if or (lt $port 1) (gt $port 65535) -}}
{{- fail (printf "components.%s: port %v is out of range" $name $c.port) -}}
{{- end -}}
{{- if not $c.health -}}
{{- fail (printf "components.%s: health is required for a component with a port — an HTTP path, or {readiness: ..., liveness: ...}" $name) -}}
{{- end -}}
{{- if kindIs "map" $c.health -}}
{{- if not (and $c.health.readiness $c.health.liveness) -}}
{{- fail (printf "components.%s: health needs both readiness and liveness paths" $name) -}}
{{- end -}}
{{- end -}}
{{- else if not $c.healthCommand -}}
{{- fail (printf "components.%s: without a port, healthCommand is required (a command that exits 0 when healthy)" $name) -}}
{{- end -}}
{{- range $k, $v := $c.env -}}
{{- /* Names like KAFKA_TOKEN_URL are locations, not secrets; any value that
       embeds a password in a URL is refused regardless of its name. */ -}}
{{- if and (regexMatch $credentialLike $k) (not (regexMatch "(?i)_(URL|URI|ENDPOINT|PATH|FILE)$" $k)) -}}
{{- fail (printf "components.%s: env %s looks like a credential — use secretEnv so the value comes from a Secret" $name $k) -}}
{{- end -}}
{{- if regexMatch "://[^/@\\s]+:[^/@\\s]+@" (toString $v) -}}
{{- fail (printf "components.%s: env %s contains a password inside a URL — use secretEnv so the value comes from a Secret" $name $k) -}}
{{- end -}}
{{- end -}}
{{- range $k, $ref := $c.secretEnv -}}
{{- $parts := splitList "/" (toString $ref) -}}
{{- if ne (len $parts) 2 -}}
{{- fail (printf "components.%s: secretEnv %s must be <alias>/<key>, e.g. credentials/svc-dml-client-secret" $name $k) -}}
{{- end -}}
{{- $alias := index $parts 0 -}}
{{- $key := index $parts 1 -}}
{{- if not (or (eq $alias "partner") (hasKey $root.Values.platform.secrets $alias)) -}}
{{- fail (printf "components.%s: secretEnv %s uses unknown alias %q (allowed: %s, partner)" $name $k $alias (keys $root.Values.platform.secrets | sortAlpha | join ", ")) -}}
{{- end -}}
{{- if not $key -}}
{{- fail (printf "components.%s: secretEnv %s has no key" $name $k) -}}
{{- end -}}
{{- /* Against a live cluster, check the key exists; otherwise the pod would
       sit in CreateContainerConfigError. Skipped under `helm template`. */ -}}
{{- $secretName := include "dnavio-component.secretName" (dict "root" $root "alias" $alias) -}}
{{- $secret := lookup "v1" "Secret" $root.Release.Namespace $secretName -}}
{{- if and $secret (not (hasKey ($secret.data | default dict) $key)) -}}
{{- fail (printf "components.%s: secretEnv %s — Secret %s has no key %q" $name $k $secretName $key) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}
