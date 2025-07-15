{{- define "frontend.name" -}}
frontend
{{- end }}

{{- define "frontend.fullname" -}}
{{ printf "%s-%s" .Release.Name (include "frontend.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "frontend.chart" -}}
{{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end }}
