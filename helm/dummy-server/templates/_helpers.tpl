{{/*
차트 이름을 반환한다.
*/}}
{{- define "dummy-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
풀네임을 반환한다. releaseName과 chartName이 같으면 중복 없이 하나만 사용한다.
*/}}
{{- define "dummy-server.fullname" -}}
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
공통 레이블
*/}}
{{- define "dummy-server.labels" -}}
app: {{ include "dummy-server.name" . }}
chart: {{ .Chart.Name }}-{{ .Chart.Version }}
release: {{ .Release.Name }}
{{- end }}

{{/*
셀렉터 레이블
*/}}
{{- define "dummy-server.selectorLabels" -}}
app: {{ include "dummy-server.name" . }}
{{- end }}
