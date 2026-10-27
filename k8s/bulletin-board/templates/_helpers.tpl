{{/* Имя чарта */}}
{{- define "bulletin-board.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Полное имя ресурсов релиза */}}
{{- define "bulletin-board.fullname" -}}
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

{{- define "bulletin-board.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "bulletin-board.selectorLabels" -}}
app.kubernetes.io/name: {{ include "bulletin-board.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "bulletin-board.labels" -}}
helm.sh/chart: {{ include "bulletin-board.chart" . }}
{{ include "bulletin-board.selectorLabels" . }}
app.kubernetes.io/version: {{ include "bulletin-board.imageTag" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: bulletin-board
{{- end }}

{{/* Тег образа: явный или appVersion. latest запрещён — релизы должны быть воспроизводимы */}}
{{- define "bulletin-board.imageTag" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag | toString }}
{{- if eq $tag "latest" }}
{{- fail "image.tag=latest запрещён: укажите конкретный тег образа" }}
{{- end }}
{{- $tag }}
{{- end }}

{{/* Имя Secret с чувствительными переменными */}}
{{- define "bulletin-board.secretName" -}}
{{- default (printf "%s-secrets" (include "bulletin-board.fullname" .)) .Values.secrets.existingSecret }}
{{- end }}

{{- define "bulletin-board.configName" -}}
{{- printf "%s-config" (include "bulletin-board.fullname" .) }}
{{- end }}
