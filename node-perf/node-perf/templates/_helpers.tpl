{{- define "node-perf.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "node-perf.fullname" -}}
{{- default .Chart.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "node-perf.labels" -}}
app.kubernetes.io/name: {{ include "node-perf.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
Benchmark matrix as env vars, consumed by node_bench.sh + bench_*.sh. Call with $root.
Lists are rendered space-joined; disk jobs as "name:rw:bs:iodepth" tokens.
*/}}
{{- define "node-perf.env" -}}
{{- $b := .Values.benchmarks -}}
- name: RESULTS
  value: {{ .Values.results.mountPath | quote }}
- name: IMAGE
  value: {{ .Values.image | quote }}
- name: REPORT_BASELINE
  value: {{ .Values.report.baselineLabel | quote }}
{{- /* ---- CPU (sysbench cpu) ---- */}}
- name: CPU_ENABLED
  value: {{ $b.cpu.enabled | quote }}
- name: CPU_THREADS
  value: {{ $b.cpu.threads | quote }}
- name: CPU_TIME
  value: {{ $b.cpu.time | quote }}
- name: CPU_MAX_PRIME
  value: {{ $b.cpu.maxPrime | quote }}
{{- /* ---- Memory (sysbench memory) ---- */}}
- name: MEM_ENABLED
  value: {{ $b.memory.enabled | quote }}
- name: MEM_THREADS
  value: {{ $b.memory.threads | quote }}
- name: MEM_TIME
  value: {{ $b.memory.time | quote }}
- name: MEM_BLOCK_SIZE
  value: {{ $b.memory.blockSize | quote }}
- name: MEM_TOTAL_SIZE
  value: {{ $b.memory.totalSize | quote }}
- name: MEM_OPER
  value: "{{ range $b.memory.oper }}{{ . }} {{ end }}"
- name: MEM_MODE
  value: "{{ range $b.memory.mode }}{{ . }} {{ end }}"
{{- /* ---- Disk (fio) ---- */}}
- name: DISK_ENABLED
  value: {{ $b.disk.enabled | quote }}
- name: DISK_ENGINE
  value: {{ $b.disk.engine | quote }}
- name: DISK_TIME
  value: {{ $b.disk.time | quote }}
- name: DISK_SIZE
  value: {{ $b.disk.size | quote }}
- name: DISK_DIRECTORY
  value: {{ $b.disk.directory | quote }}
- name: DISK_JOBS
  value: "{{ range $b.disk.jobs }}{{ .name }}:{{ .rw }}:{{ .bs }}:{{ .iodepth }} {{ end }}"
{{- end -}}

{{/*
Container block shared by every node-perf pod.
Call with a dict: {"ctx": $root, "command": <list-as-string>}
*/}}
{{- define "node-perf.container" -}}
- name: bench
  image: {{ .ctx.Values.image }}
  imagePullPolicy: {{ .ctx.Values.imagePullPolicy }}
  command: {{ .command }}
  workingDir: {{ .ctx.Values.results.mountPath }}
  env:
    {{- include "node-perf.env" .ctx | nindent 4 }}
    - name: NODE_NAME
      valueFrom:
        fieldRef:
          fieldPath: spec.nodeName
  securityContext:
    {{- if .ctx.Values.privileged }}
    privileged: true
    {{- end }}
  resources:
    {{- if or .ctx.Values.resources.cpu .ctx.Values.resources.memory }}
    limits:
      {{- with .ctx.Values.resources.cpu }}
      cpu: {{ . | quote }}
      {{- end }}
      {{- with .ctx.Values.resources.memory }}
      memory: {{ . | quote }}
      {{- end }}
    requests:
      {{- with .ctx.Values.resources.cpu }}
      cpu: {{ . | quote }}
      {{- end }}
      {{- with .ctx.Values.resources.memory }}
      memory: {{ . | quote }}
      {{- end }}
    {{- else }}
    {}
    {{- end }}
  volumeMounts:
    - name: scripts
      mountPath: {{ .ctx.Values.script.mountPath }}
    - name: results
      mountPath: {{ .ctx.Values.results.mountPath }}
    - name: disk-scratch
      mountPath: {{ .ctx.Values.diskScratch.mountPath }}
{{- end -}}

{{/*
Volumes block shared by every node-perf pod.
*/}}
{{- define "node-perf.volumes" -}}
- name: scripts
  configMap:
    name: {{ include "node-perf.fullname" . }}-scripts
    defaultMode: 0555
- name: results
{{- if .Values.results.pvcName }}
  persistentVolumeClaim:
    claimName: {{ .Values.results.pvcName }}
{{- else if .Values.results.hostPath }}
  hostPath:
    path: {{ .Values.results.hostPath | quote }}
    type: DirectoryOrCreate
{{- else }}
  emptyDir: {}
{{- end }}
- name: disk-scratch
  hostPath:
    path: {{ .Values.diskScratch.hostPath | quote }}
    type: DirectoryOrCreate
{{- end -}}
