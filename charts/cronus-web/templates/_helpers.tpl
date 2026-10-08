{{/*
Labels applied to every object in this chart.

The name is the chart name rather than a release-derived one on purpose, so that the Service sits at a
predictable address and the two environments of this application are distinguishable by namespace
rather than by a name that depends on how the release was installed.

`cronus.io/environment` is derived from the namespace rather than repeated in every values file, so it
cannot drift from where the objects are. It is deliberately absent from the selector below, which is
immutable once the Deployment exists.
*/}}
{{- define "cronus-web.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: cronus
app.kubernetes.io/managed-by: {{ .Release.Service }}
cronus.io/environment: {{ .Release.Namespace | trimPrefix "cronus-" }}
{{- end }}

{{/*
The labels that select the pods: the Deployment's selector, its pod template and the Service's
selector all use this, and they have to agree.

`component: server` is carried for consistency with the two backend charts, where the same label keeps
a Service from selecting its migration job's pods. Nothing competes with these pods yet, and stating
the component now means the selector does not have to change if something ever does.

Kept separate from the labels above because a Deployment's selector is immutable once it exists, so
nothing that could change for a reason unrelated to identity belongs in it.
*/}}
{{- define "cronus-web.serverSelector" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: server
{{- end }}

{{/*
The name of the ConfigMap that supplies /config.js.

Fixed rather than release-derived, like the labels above, so that the file the container serves and
the object behind it are found by the same name in both environments.
*/}}
{{- define "cronus-web.runtimeConfigName" -}}
{{ .Chart.Name }}-runtime-config
{{- end }}

{{/*
Use the digest for pulls when supplied; keep the tag for readable release diffs.
Without a digest, dev and staging pull by tag. Validate supplied digests before rendering.
*/}}
{{- define "cronus-web.image" -}}
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
