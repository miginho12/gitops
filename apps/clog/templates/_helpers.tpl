{{/*
Expand the name of the chart.
*/}}
{{- define "clog.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "clog.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart name and version
*/}}
{{- define "clog.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "clog.labels" -}}
helm.sh/chart: {{ include "clog.chart" . }}
{{ include "clog.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "clog.selectorLabels" -}}
app.kubernetes.io/name: {{ include "clog.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
API(웹) Pod 전용 selector (감사 M12) — worker·CronJob Pod 는 component 가 달라 제외된다.
Deployment selector 는 immutable 이라 바꿀 때는 orphan 삭제 후 재생성 (gitops 커밋 메시지 참고).
*/}}
{{- define "clog.apiSelectorLabels" -}}
{{ include "clog.selectorLabels" . }}
app.kubernetes.io/component: api
{{- end }}

{{/*
ServiceAccount name
*/}}
{{- define "clog.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "clog.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
