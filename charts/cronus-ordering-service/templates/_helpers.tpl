{{/*
Labels applied to every object in this chart.

The name is the chart name rather than a release-derived one on purpose: the Service has to be
reachable at a fixed address, because the HTTPRoute sends /api to http://cronus-ordering-service:8080
and that hostname is part of the contract between the two.

`cronus.io/environment` is derived from the namespace rather than repeated in every values file. The
namespace *is* `cronus-<environment>`, so the label cannot drift from where the objects actually are,
and a values file that forgot to set it could not exist. It is deliberately absent from the selector
below: a Deployment's selector is immutable, and nothing that could change for a reason unrelated to
identity belongs in it.
*/}}
{{- define "cronus-ordering-service.labels" -}}
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
{{- define "cronus-ordering-service.serverSelector" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: server
{{- end }}

{{/*
Share host and database settings while runtime and migration jobs name different roles.
Never embed stored credentials; the service obtains Entra tokens from workload identity.
*/}}
{{- define "cronus-ordering-service.connectionString" -}}
Host={{ required "database.host is required" .host }};Database={{ required "database.name is required" .name }};Username={{ required "a database username is required" .username }};Ssl Mode=Require
{{- end }}

{{/*
Use the digest for pulls when supplied; keep the tag for readable release diffs.
Without a digest, dev and staging pull by tag. Validate supplied digests before rendering.
*/}}
{{- define "cronus-ordering-service.image" -}}
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
