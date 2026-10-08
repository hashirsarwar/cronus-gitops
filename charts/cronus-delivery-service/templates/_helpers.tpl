{{/*
Labels applied to every object in this chart.

The name is the chart name rather than a release-derived one on purpose: the Service has to be
reachable at a fixed address, because the ordering service calls it at
http://cronus-delivery-service:8080 and that hostname is part of the contract between the two charts.

`cronus.io/environment` is derived from the namespace rather than repeated in every values file, so it
cannot drift from where the objects are. It is deliberately absent from the selector below, which is
immutable once the Deployment exists.
*/}}
{{- define "cronus-delivery-service.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: cronus
app.kubernetes.io/managed-by: {{ .Release.Service }}
cronus.io/environment: {{ .Release.Namespace | trimPrefix "cronus-" }}
{{- end }}

{{/*
Keep server selectors shared and stable: Deployment selectors are immutable.
The server component excludes migration and seed pods from Service traffic.
*/}}
{{- define "cronus-delivery-service.serverSelector" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: server
{{- end }}

{{/*
Share host and database settings while runtime and migration jobs name different roles.
Never embed stored credentials; the service obtains Entra tokens from workload identity.
*/}}
{{- define "cronus-delivery-service.connectionString" -}}
Host={{ required "database.host is required" .host }};Database={{ required "database.name is required" .name }};Username={{ required "a database username is required" .username }};Ssl Mode=Require
{{- end }}

{{/*
Use the digest for pulls when supplied; keep the tag for readable release diffs.
Without a digest, dev and staging pull by tag. Validate supplied digests before rendering.
*/}}
{{- define "cronus-delivery-service.image" -}}
{{- $tag := required "image.tag is required: it must be the immutable tag of the build being deployed" .Values.image.tag -}}
{{- $digest := .Values.image.digest -}}
{{- if $digest -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" $digest) -}}
{{- fail (printf "image.digest must be a sha256 digest: sha256: followed by 64 lowercase hexadecimal characters. Got %q. It is the digest a registry reports, not a tag and not a repository@digest reference." $digest) -}}
{{- end -}}
{{- printf "%s@%s" .Values.image.repository $digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
{{- end }}
