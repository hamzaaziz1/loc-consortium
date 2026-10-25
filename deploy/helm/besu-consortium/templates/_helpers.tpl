{{- define "besu.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "besu.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
The stable DNS name of a node's pod.

A StatefulSet of one replica behind a headless service gives <name>-0 a DNS
record that survives rescheduling. This is what replaces the fixed IP
addresses the Compose stack uses, and it is the reason the chart needs an init
container: Besu's static node list requires IP addresses, not names, so the
names have to be resolved somewhere. See ADR on enode addressing.
*/}}
{{- define "besu.nodeDNS" -}}
{{- printf "%s-%s-0.%s-headless.%s.svc.cluster.local" .release .node .release .namespace -}}
{{- end -}}
