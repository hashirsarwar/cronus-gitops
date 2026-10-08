{{/*
These object labels support discovery; NetworkPolicy traffic selection comes from spec selectors.
Derive the environment from the namespace so identity labels cannot drift from placement.
*/}}
{{- define "cronus-network-policies.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: cronus
app.kubernetes.io/managed-by: {{ .Release.Service }}
cronus.io/environment: {{ .Release.Namespace | trimPrefix "cronus-" }}
{{- end }}
