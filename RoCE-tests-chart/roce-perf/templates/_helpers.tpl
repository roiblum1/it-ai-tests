{{- define "roce-perf.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "roce-perf.fullname" -}}
{{- default .Chart.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "roce-perf.labels" -}}
app.kubernetes.io/name: {{ include "roce-perf.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
Benchmark matrix as env vars, consumed by roce_bench.sh. Call with $root.
*/}}
{{- define "roce-perf.env" -}}
{{- $b := .Values.benchmarks -}}
- name: MTU
  value: {{ .Values.mtu | quote }}
- name: RESULTS
  value: {{ .Values.results.mountPath | quote }}
- name: IMAGE
  value: {{ .Values.image | quote }}
- name: BW_READ_ENABLED
  value: {{ $b.bw.read.enabled | quote }}
- name: BW_READ_DURATION
  value: {{ $b.bw.read.duration | quote }}
- name: BW_READ_SIZES
  value: "{{ range $b.bw.read.sizes }}{{ . }} {{ end }}"
- name: BW_READ_QPS
  value: {{ $b.bw.read.qps | quote }}
- name: BW_WRITE_ENABLED
  value: {{ $b.bw.write.enabled | quote }}
- name: BW_WRITE_DURATION
  value: {{ $b.bw.write.duration | quote }}
- name: BW_WRITE_SIZES
  value: "{{ range $b.bw.write.sizes }}{{ . }} {{ end }}"
- name: BW_WRITE_QPS
  value: {{ $b.bw.write.qps | quote }}
- name: LAT_WRITE_ENABLED
  value: {{ $b.lat.write.enabled | quote }}
- name: LAT_WRITE_ITERS
  value: {{ $b.lat.write.iters | quote }}
- name: LAT_WRITE_SIZE
  value: {{ $b.lat.write.size | quote }}
- name: LAT_WRITE_UNSORTED
  value: {{ $b.lat.write.unsorted | quote }}
- name: LAT_READ_ENABLED
  value: {{ $b.lat.read.enabled | quote }}
- name: LAT_READ_ITERS
  value: {{ $b.lat.read.iters | quote }}
- name: LAT_READ_SIZE
  value: {{ $b.lat.read.size | quote }}
- name: LAT_READ_UNSORTED
  value: {{ $b.lat.read.unsorted | quote }}
- name: LAT_SEND_ENABLED
  value: {{ $b.lat.send.enabled | quote }}
- name: LAT_SEND_ITERS
  value: {{ $b.lat.send.iters | quote }}
- name: LAT_SEND_SIZE
  value: {{ $b.lat.send.size | quote }}
- name: LAT_SEND_UNSORTED
  value: {{ $b.lat.send.unsorted | quote }}
- name: GPUDIRECT_ENABLED
  value: {{ .Values.gpudirect.enabled | quote }}
- name: GPUDIRECT_SKIP
  value: "{{ range .Values.gpudirect.skip }}{{ . }} {{ end }}"
- name: NUMACTL_ENABLED
  value: {{ .Values.numactl.enabled | quote }}
- name: NUMA_NODE
  value: {{ .Values.numactl.node | quote }}
{{- /* GPU_INDEX is per-pod (paired with each pod's nic), added by roce-perf.container */}}
- name: NCCL_COLLECTIVE
  value: {{ .Values.nccl.collective | quote }}
- name: NCCL_SIZE_BEGIN
  value: {{ .Values.nccl.sizes.begin | quote }}
- name: NCCL_SIZE_END
  value: {{ .Values.nccl.sizes.end | quote }}
- name: NCCL_SIZE_FACTOR
  value: {{ .Values.nccl.sizes.factor | quote }}
- name: NCCL_GPUS
  value: {{ .Values.nccl.gpus | quote }}
- name: NCCL_HCA_ONE
  value: {{ .Values.nccl.hcaOne | quote }}
- name: NCCL_HCA_ALL
  value: {{ .Values.nccl.hcaAll | quote }}
- name: NCCL_IB_GID_INDEX_CFG
  value: {{ .Values.nccl.ib.gidIndex | quote }}
- name: NCCL_SOCKET_IFNAME_CFG
  value: {{ .Values.nccl.ib.socketIfname | quote }}
- name: NCCL_IB_DISABLE_CFG
  value: {{ .Values.nccl.ib.disable | quote }}
- name: NCCL_DEBUG_CFG
  value: {{ .Values.nccl.ib.debug | quote }}
- name: NCCL_SHM_DISABLE_CFG
  value: {{ .Values.nccl.shm.disable | quote }}
{{- end -}}

{{/*
Renders the container block shared by every pod.
Call with a dict: {"ctx": $root, "resource": <device-plugin resource>, "gpuIndex": <int>, "command": <list-as-string>}
*/}}
{{- define "roce-perf.container" -}}
- name: rdma
  image: {{ .ctx.Values.image }}
  imagePullPolicy: {{ .ctx.Values.imagePullPolicy }}
  command: {{ .command }}
  workingDir: {{ .ctx.Values.results.mountPath }}
  env:
    {{- include "roce-perf.env" .ctx | nindent 4 }}
    - name: GPU_INDEX
      value: {{ .gpuIndex | quote }}
  securityContext:
    {{- if .ctx.Values.privileged }}
    privileged: true
    {{- end }}
    capabilities:
      add: {{ if .ctx.Values.ipcLock }}["IPC_LOCK"]{{ else }}[]{{ end }}
  resources:
    limits:
      {{ .resource | quote }}: "1"
      {{- if .ctx.Values.gpudirect.enabled }}
      nvidia.com/gpu: "1"
      {{- end }}
      {{- with .ctx.Values.resources.cpu }}
      cpu: {{ . | quote }}
      {{- end }}
      {{- with .ctx.Values.resources.memory }}
      memory: {{ . | quote }}
      {{- end }}
    requests:
      {{ .resource | quote }}: "1"
      {{- if .ctx.Values.gpudirect.enabled }}
      nvidia.com/gpu: "1"
      {{- end }}
      {{- with .ctx.Values.resources.cpu }}
      cpu: {{ . | quote }}
      {{- end }}
      {{- with .ctx.Values.resources.memory }}
      memory: {{ . | quote }}
      {{- end }}
  volumeMounts:
    - name: scripts
      mountPath: {{ .ctx.Values.script.mountPath }}
    - name: results
      mountPath: {{ .ctx.Values.results.mountPath }}
{{- end -}}

{{/*
Renders the volumes block shared by every pod.
*/}}
{{- define "roce-perf.volumes" -}}
- name: scripts
  configMap:
    name: {{ include "roce-perf.fullname" . }}-scripts
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
{{- end -}}
