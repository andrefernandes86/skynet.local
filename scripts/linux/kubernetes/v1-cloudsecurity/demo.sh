#!/usr/bin/env bash
# demo-suite.sh - Categorized menu to manage Trend Micro demos on your K8s lab
#
# MAIN
#  1) Status
#  2) Platform Tools
#  q) Quit
#
# PLATFORM TOOLS
#  1) Check status (installed + pods by node)
#  2) Container Security
#  3) File Security
#  4) Show URLs
#  5) Validate & Clean Up previous components   <-- NEW
#  b) Back
#
# CONTAINER SECURITY
#  1) Install/Upgrade Container Security (with TTL enforcer)
#  2) Remove Container Security
#  3) Deploy Demos (DVWA + Malware, OpenWebUI + Ollama)
#  4) Remove Demos
#  b) Back
#
# FILE SECURITY
#  1) Install/Upgrade File Security (expose via NodePort + TTL enforcer)
#  2) Remove File Security
#  3) Start ICAP port-forward (0.0.0.0:1344 -> svc/*-scanner:1344)
#  4) Stop  ICAP port-forward
#  5) Status ICAP port-forward
#  b) Back
#
# Notes:
# - TTL enforcer prevents leftover trendmicro-scan-job-* by patching ttlSecondsAfterFinished.
# - File Security scanner is exposed via NodePort and also supports a port-forward listener for ICAP on 0.0.0.0:1344.

set -euo pipefail

# -------- Config --------
REL_CS="trendmicro"                       # Container Security Helm release
NS_CS="trendmicro-system"
CS_CHART_URL="https://github.com/trendmicro/visionone-container-security-helm/archive/main.tar.gz"
OVERRIDES="./overrides.yaml"

FS_NS="visionone-filesecurity"            # File Security namespace
FS_REL_DEFAULT="my-release"
FS_NODEPORT_SVC="v1fs-scanner-nodeport"
FS_NODEPORT=32051                         # external port for gRPC (scanner listens on 50051)

OPENWEBUI_NODEPORT=30080
OLLAMA_NODEPORT=31134

# TTL enforcer (deployed to NS_CS, works cluster-wide)
TTL_ENF_SA="scanjob-ttl-enforcer"
TTL_ENF_CR="scanjob-ttl-enforcer"
TTL_ENF_CRB="scanjob-ttl-enforcer"
TTL_ENF_CJ="scanjob-ttl-enforcer"
TTL_SECONDS="${TTL_SECONDS:-600}"         # default 10 minutes

# -------- ICAP Port-Forward (network-accessible) --------
PF_ADDR="${PF_ADDR:-0.0.0.0}"            # listen on all interfaces
PF_LOCAL_ICP="${PF_LOCAL_ICP:-1344}"     # local/listening port on this host
PF_REMOTE_ICP="${PF_REMOTE_ICP:-1344}"   # remote service port (ICAP)
PF_PIDFILE="${PF_PIDFILE:-/var/run/v1fs_icap_pf.pid}"
PF_LOG="${PF_LOG:-/var/log/v1fs_icap_pf.log}"

# -------- Styling (ASCII-safe) --------
BOLD=$'\e[1m'; RESET=$'\e[0m'
WARN="⚠️ "; ERR="❌"; OK="✅"; INFO="ℹ️ "
is_utf8(){ [ "${FORCE_ASCII:-0}" = "1" ] && return 1; locale charmap 2>/dev/null | grep -qi 'utf-8'; }
hr(){ local cols; cols="$(tput cols 2>/dev/null || echo 80)"; if is_utf8; then printf "%*s\n" "$cols" | tr ' ' '─'; else printf "%*s\n" "$cols" | tr ' ' '-'; fi; }
box(){ local t="$1"; hr; if is_utf8; then printf "\e[1m%s\e[0m\n" "$t"; else printf "%s\n" "$t"; fi; hr; }
need(){ command -v "$1" >/dev/null || { echo "${ERR} Missing: $1"; exit 1; } }
kdel(){ # best-effort delete
  kubectl "$@" 2>/dev/null || true
}

# -------- Node discovery --------
node_ip(){ local n="${1:-}"; [ -z "$n" ] && return 0; kubectl get node "$n" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true; }
has_node(){ kubectl get node "$1" >/dev/null 2>&1; }
detect_master(){
  local m
  m=$(kubectl get nodes -l 'node-role.kubernetes.io/control-plane' -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  [ -z "$m" ] && m=$(kubectl get nodes -l 'node-role.kubernetes.io/master' -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  [ -z "$m" ] && has_node "lab-kube-master" && m="lab-kube-master"
  [ -z "$m" ] && m=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
  echo "$m" | head -n1
}
detect_workers(){
  local master="$1"; local w1=""; local w2=""
  has_node "lab-kube-node1" && w1="lab-kube-node1"
  has_node "lab-kube-node2" && w2="lab-kube-node2"
  if [ -z "$w1" ] || [ -z "$w2" ]; then
    mapfile -t all < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    for n in "${all[@]}"; do
      [ "$n" = "$master" ] && continue
      [ "$n" = "$w1" ] && continue
      [ "$n" = "$w2" ] && continue
      if [ -z "$w1" ]; then w1="$n"; continue; fi
      if [ -z "$w2" ]; then w2="$n"; continue; fi
    done
  fi
  echo "$w1" "$w2"
}
print_nodes_table(){
  local master="$1" node1="$2" node2="$3"
  box "Cluster Nodes"
  printf "%-10s %-24s %-15s %-s\n" "ROLE" "NAME" "INTERNAL-IP" "KUBELET-VERSION"
  hr
  printf "%-10s %-24s %-15s %-s\n" "master" "$master" "$(node_ip "$master")" "$(kubectl get node "$master" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null)"
  [ -n "$node1" ] && printf "%-10s %-24s %-15s %-s\n" "node1" "$node1" "$(node_ip "$node1")" "$(kubectl get node "$node1" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null)"
  [ -n "$node2" ] && printf "%-10s %-24s %-15s %-s\n" "node2" "$node2" "$(node_ip "$node2")" "$(kubectl get node "$node2" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null)"
  hr
}
node_ips_all(){ kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' | sort -u; }

# -------- Install/Status helpers --------
installed_cs(){ helm status "$REL_CS" -n "$NS_CS" >/dev/null 2>&1 && echo "yes" || echo ""; }
find_fs_release(){
  helm list -n "$FS_NS" -o json 2>/dev/null | awk -v IGNORECASE=1 -F'"' '/visionone-filesecurity/ {for(i=1;i<=NF;i++){if($i=="name"){print $(i+2); exit}}}'
}
installed_fs(){ local r; r="$(find_fs_release)"; [ -n "$r" ] && echo "$r" || echo ""; }
ensure_ns(){ kubectl create ns "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }

# ======= TTL ENFORCER (prevents leftover scan jobs) =======
install_ttl_enforcer(){
  echo "${INFO} Installing TTL enforcer (ttlSecondsAfterFinished=${TTL_SECONDS})"
  ensure_ns "$NS_CS"

  kubectl -n "$NS_CS" apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${TTL_ENF_SA}
  namespace: ${NS_CS}
EOF

  kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${TTL_ENF_CR}
rules:
- apiGroups: ["batch"]
  resources: ["jobs"]
  verbs: ["get","list","watch","patch","update"]
EOF

  kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${TTL_ENF_CRB}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${TTL_ENF_CR}
subjects:
- kind: ServiceAccount
  name: ${TTL_ENF_SA}
  namespace: ${NS_CS}
EOF

  kubectl -n "$NS_CS" apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ${TTL_ENF_CJ}
spec:
  schedule: "*/5 * * * *"
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: ${TTL_ENF_SA}
          restartPolicy: OnFailure
          containers:
          - name: kubectl
            image: bitnami/kubectl:1.30
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh","-c"]
            args:
              - |
                set -eu
                kubectl get jobs -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' \
                | awk -F'\t' '\$2 ~ /^trendmicro-scan-job-/' \
                | while IFS=\$'\t' read ns name; do
                    kubectl -n "\$ns" patch job "\$name" --type=merge -p '{"spec":{"ttlSecondsAfterFinished":'"${TTL_SECONDS}"'}}' >/dev/null 2>&1 || true
                  done
EOF

  echo "${OK} TTL enforcer deployed."
}
remove_ttl_enforcer(){
  echo "${INFO} Removing TTL enforcer..."
  kdel -n "$NS_CS" delete cronjob "${TTL_ENF_CJ}" --ignore-not-found
  kdel delete clusterrolebinding "${TTL_ENF_CRB}" --ignore-not-found
  kdel delete clusterrole "${TTL_ENF_CR}" --ignore-not-found
  kdel -n "$NS_CS" delete serviceaccount "${TTL_ENF_SA}" --ignore-not-found
  echo "${OK} TTL enforcer removed."
}
cleanup_scan_jobs_now(){
  echo "${INFO} Forcing cleanup of trendmicro-scan-job-* by setting TTL=1s..."
  kubectl get jobs -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' \
  | awk -F'\t' '$2 ~ /^trendmicro-scan-job-/' \
  | while IFS=$'\t' read -r ns name; do
      kubectl -n "$ns" patch job "$name" --type=merge -p '{"spec":{"ttlSecondsAfterFinished":1}}' >/dev/null 2>&1 || true
    done
  echo "${OK} TTL set; K8s TTL controller will delete finished jobs promptly."
}

# ===================== STATUS =====================
status_check(){
  need kubectl; need helm
  local master node1 node2
  master="$(detect_master)"; read -r node1 node2 <<<"$(detect_workers "$master")"
  print_nodes_table "$master" "$node1" "$node2"

  box "What is Installed"
  [ -n "$(installed_cs)" ] && echo "Container Security: installed (release: ${REL_CS}, ns: ${NS_CS})" \
                            || echo "Container Security: not installed"
  local fsrel; fsrel="$(installed_fs)"
  [ -n "$fsrel" ] && echo "File Security: installed (release: ${fsrel}, ns: ${FS_NS})" \
                  || echo "File Security: not installed"

  echo
  box "Pods by Node"
  for n in $(kubectl get nodes -o name | cut -d/ -f2); do
    echo "=== $n ==="
    kubectl get pods -A --field-selector spec.nodeName="$n" -o wide
    echo
  done
}
status_board(){
  box "Status Board (pods across cluster)"
  printf "%-16s %-38s %-9s %-10s %-16s %-15s\n" "NAMESPACE" "NAME" "READY" "STATUS" "NODE" "POD-IP"
  hr
  kubectl get pods -A -o wide --no-headers | awk '{printf "%-16s %-38s %-9s %-10s %-16s %-15s\n", $1,$2,$3,$4,$8,$6}'
  echo

  box "Key Namespaces Summary"
  echo "Container Security (${NS_CS}):"; kubectl -n "$NS_CS" get deploy,ds,po -o wide || true; echo
  echo "File Security (${FS_NS}):";     kubectl -n "$FS_NS" get deploy,svc,po -o wide || true; echo
  echo "Default (demos):";              kubectl -n default get deploy,svc,po -o wide || true
}

# Safe under set -e: no && short-circuits; always returns 0
status_urls(){
  set +e
  local master node1 node2; master="$(detect_master)"; read -r node1 node2 <<<"$(detect_workers "$master")"
  local node2ip; node2ip="$(node_ip "$node2")"
  local ips; ips="$(node_ips_all)"

  box "Remote and Internal Access URLs"

  echo "Malicious Lab (hostPorts on node2)"
  if [ -n "$node2ip" ]; then
    echo "  DVWA_VulnerableWebApp  ->  http://${node2ip}:8080"
    echo "  Malware_Samples        ->  http://${node2ip}:8081"
  else
    echo "  ${WARN}node2 IP not found. Ensure a worker is available for hostPorts."
  fi
  echo

  echo "Normal Lab (NodePorts on any node)"
  for ip in $ips; do
    if kubectl -n default get svc openwebui >/dev/null 2>&1; then
      echo "  OpenWebUI              ->  http://${ip}:${OPENWEBUI_NODEPORT}"
    fi
    if kubectl -n default get svc ollama >/dev/null 2>&1; then
      echo "  Ollama API             ->  http://${ip}:${OLLAMA_NODEPORT}/api/version"
    fi
  done
  echo

  echo "Vision One File Security gRPC (NodePort)"
  if kubectl -n "$FS_NS" get svc "$FS_NODEPORT_SVC" >/dev/null 2>&1; then
    for ip in $ips; do echo "  Scanner                ->  ${ip}:${FS_NODEPORT}"; done
  else
    echo "  ${WARN}Service ${FS_NODEPORT_SVC} not found in ${FS_NS}."
  fi

  set -e; return 0
}

# ===================== PLATFORM TOOLS: Container Security =====================
remove_cs(){
  echo "${INFO} Cleaning scan jobs first..."; cleanup_scan_jobs_now
  echo "${INFO} Removing TTL enforcer...";   remove_ttl_enforcer
  echo "${INFO} Uninstalling Container Security..."
  kdel uninstall "$REL_CS" -n "$NS_CS"
  kdel delete ns "$NS_CS" --wait=false
  echo "${OK} Container Security removed."
}
install_cs(){
  need kubectl; need helm
  echo "== Install or Upgrade Trend Micro Vision One Container Security =="
  read -r -p "Paste NEW Vision One bootstrap token: " BOOTSTRAP_TOKEN
  [ -z "${BOOTSTRAP_TOKEN}" ] && { echo "Token cannot be empty"; exit 1; }
  echo "Choose tenant region:
  1) US  api.xdr.trendmicro.com
  2) EU  api.eu.xdr.trendmicro.com
  3) JP  api.xdr.trendmicro.co.jp
  4) AU  api.au.xdr.trendmicro.com
  5) SG  api.sg.xdr.trendmicro.com"
  read -r -p "Enter 1..5 [default 1]: " CHOICE; CHOICE="${CHOICE:-1}"
  case "$CHOICE" in
    1) API_HOST="api.xdr.trendmicro.com" ;;
    2) API_HOST="api.eu.xdr.trendmicro.com" ;;
    3) API_HOST="api.xdr.trendmicro.co.jp" ;;
    4) API_HOST="api.au.xdr.trendmicro.com" ;;
    5) API_HOST="api.sg.xdr.trendmicro.com" ;;
    *) API_HOST="api.xdr.trendmicro.com" ;;
  esac
  ENDPOINT="https://${API_HOST}/external/v2/direct/vcs/external/vcs"

  [ -f "$OVERRIDES" ] && cp "$OVERRIDES" "${OVERRIDES}.$(date +%Y%m%d-%H%M%S).bak"
  cat > "$OVERRIDES" <<EOF
visionOne:
  bootstrapToken: ${BOOTSTRAP_TOKEN}
  endpoint: ${ENDPOINT}
  exclusion:
    namespaces: [kube-system]
  runtimeSecurity:         { enabled: true }
  vulnerabilityScanning:   { enabled: true }
  malwareScanning:         { enabled: true }
  secretScanning:          { enabled: true }
  inventoryCollection:     { enabled: true }
EOF
  echo "Wrote $OVERRIDES"

  if helm status "$REL_CS" -n "$NS_CS" >/dev/null 2>&1; then
    echo "Release exists -> upgrading..."
    helm get values --namespace "$NS_CS" "$REL_CS" | helm upgrade \
      "$REL_CS" --namespace "$NS_CS" --values "$OVERRIDES" "$CS_CHART_URL" || true
  else
    echo "Installing new release..."
    helm install "$REL_CS" --namespace "$NS_CS" --create-namespace \
      --values "$OVERRIDES" "$CS_CHART_URL"
  fi

  echo "Waiting for core components..."
  components=(
    trendmicro-oversight-controller
    trendmicro-scan-manager
    trendmicro-policy-operator
    trendmicro-metacollector
    trendmicro-admission-controller
    trendmicro-usage-controller
    trendmicro-scout      # optional in some chart versions
  )
  for d in "${components[@]}"; do
    if kubectl -n "$NS_CS" get deploy "$d" >/dev/null 2>&1; then
      kubectl -n "$NS_CS" rollout status deploy "$d" --timeout=180s || true
    else
      echo "${INFO} Skipping rollout wait for missing deployment: $d"
    fi
  done

  install_ttl_enforcer
  echo "${OK} Container Security ready."
}

# ===================== PLATFORM TOOLS: File Security =====================
remove_fs(){
  echo "${INFO} Cleaning scan jobs first..."; cleanup_scan_jobs_now
  local rel; rel="$(installed_fs)"; if [ -z "$rel" ]; then rel="$FS_REL_DEFAULT"; fi
  echo "${INFO} Uninstalling File Security (${rel})..."
  kdel uninstall "$rel" -n "$FS_NS"
  kdel delete ns "$FS_NS" --wait=false
  echo "${OK} File Security removed."
}
install_fs(){
  need kubectl; need helm
  echo "== Install or Upgrade Trend Vision One File Security =="
  read -r -p "Paste File Security REGISTRATION TOKEN: " FS_TOKEN
  [ -z "$FS_TOKEN" ] && { echo "Token cannot be empty"; exit 1; }

  ensure_ns "$FS_NS"
  kubectl -n "$FS_NS" create secret generic token-secret \
    --from-literal=registration-token="$FS_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$FS_NS" create secret generic device-token-secret \
    --dry-run=client -o yaml | kubectl apply -f -

  helm repo add visionone-filesecurity https://trendmicro.github.io/visionone-file-security-helm/ >/dev/null
  helm repo update >/dev/null
  local rel; rel="$(installed_fs)"; if [ -z "$rel" ]; then rel="$FS_REL_DEFAULT"; fi
  helm upgrade --install "$rel" visionone-filesecurity/visionone-filesecurity -n "$FS_NS"

  echo "Waiting for scanner to be Ready..."
  kubectl -n "$FS_NS" rollout status deploy "$rel-visionone-filesecurity-scanner" --timeout=300s || true

  # Expose scanner via NodePort (persistent, chart-independent)
  cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${FS_NODEPORT_SVC}
  namespace: ${FS_NS}
  labels:
    app.kubernetes.io/name: visionone-filesecurity-scanner
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: visionone-filesecurity-scanner
  ports:
    - name: grpc
      port: 50051
      targetPort: 50051
      protocol: TCP
      nodePort: ${FS_NODEPORT}
YAML

  install_ttl_enforcer
  echo "${OK} File Security exposed at NodePort ${FS_NODEPORT_SVC}:${FS_NODEPORT}"
}

# ===================== OpenWebUI Secret helper =====================
ensure_openwebui_secret(){
  ensure_ns default
  local key="${WEBUI_SECRET_KEY:-}"
  if [ -z "$key" ]; then
    key="$(head -c32 /dev/urandom | base64 | tr -d '=+/ \n' | cut -c1-64)"
  fi
  kubectl -n default create secret generic openwebui-secret \
    --from-literal=WEBUI_SECRET_KEY="$key" \
    --dry-run=client -o yaml | kubectl apply -f -
}

# ===================== ICAP Port-Forward Helpers =====================
icap_release_name(){ local rel; rel="$(installed_fs)"; [ -z "$rel" ] && rel="$FS_REL_DEFAULT"; echo "$rel"; }
icap_svc_name(){ echo "$(icap_release_name)-visionone-filesecurity-scanner"; }
icap_pf_is_running(){ [ -f "$PF_PIDFILE" ] || return 1; local pid; pid="$(cat "$PF_PIDFILE" 2>/dev/null || true)"; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
icap_pf_status(){
  if icap_pf_is_running; then echo "${OK} ICAP port-forward is running (pid $(cat "$PF_PIDFILE"))."; else echo "${WARN} ICAP port-forward is NOT running."; fi
  if command -v ss >/dev/null; then ss -ltn | awk -v p=":${PF_LOCAL_ICP}" '$4 ~ p'; else netstat -ltn 2>/dev/null | awk -v p=":${PF_LOCAL_ICP}" '$4 ~ p'; fi
  echo "Reachable URLs on this host:"; for ip in $(hostname -I 2>/dev/null); do echo "  icap://$ip:${PF_LOCAL_ICP}"; done
}
icap_pf_start(){
  need kubectl; ensure_ns "$FS_NS"
  local svc; svc="$(icap_svc_name)"
  if ! kubectl -n "$FS_NS" get svc "$svc" >/dev/null 2>&1; then
    echo "${ERR} Service $svc not found in namespace $FS_NS."; echo "      Make sure File Security is installed and the scanner Service exists."; return 1; fi
  if icap_pf_is_running; then echo "${INFO} Port-forward already running (pid $(cat "$PF_PIDFILE"))."; icap_pf_status; return 0; fi
  echo "${INFO} Starting ICAP port-forward on ${PF_ADDR}:${PF_LOCAL_ICP} -> ${svc}:${PF_REMOTE_ICP}"
  mkdir -p "$(dirname "$PF_LOG")" "$(dirname "$PF_PIDFILE")"
  nohup kubectl -n "$FS_NS" port-forward "svc/${svc}" "${PF_LOCAL_ICP}:${PF_REMOTE_ICP}" --address "${PF_ADDR}" --pod-running-timeout=2m >> "$PF_LOG" 2>&1 &
  echo $! > "$PF_PIDFILE"; sleep 1
  if icap_pf_is_running; then echo "${OK} Port-forward started. Log: $PF_LOG"; icap_pf_status; else echo "${ERR} Failed to start port-forward. Check $PF_LOG"; rm -f "$PF_PIDFILE"; return 1; fi
}
icap_pf_stop(){
  if ! icap_pf_is_running; then echo "${INFO} No active ICAP port-forward."; return 0; fi
  local pid; pid="$(cat "$PF_PIDFILE")"; echo "${INFO} Stopping port-forward (pid $pid)..."
  kill "$pid" 2>/dev/null || true; sleep 1
  if kill -0 "$pid" 2>/dev/null; then echo "${WARN} Force killing $pid"; kill -9 "$pid" 2>/dev/null || true; fi
  rm -f "$PF_PIDFILE"; echo "${OK} Stopped."
}

# ===================== DEMOS =====================
deploy_malicious(){
  local master node1 node2; master="$(detect_master)"; read -r node1 node2 <<<"$(detect_workers "$master")"
  [ -z "$node2" ] && { echo "${ERR} Could not find node2 to pin hostPorts."; exit 1; }
  cat <<YAML | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dvwa-vulnerablewebapp
  namespace: default
  labels: { app: DVWA_VulnerableWebApp, app.kubernetes.io/part-of: security-demos }
spec:
  replicas: 1
  selector: { matchLabels: { app: DVWA_VulnerableWebApp } }
  template:
    metadata: { labels: { app: DVWA_VulnerableWebApp, app.kubernetes.io/part-of: security-demos } }
    spec:
      nodeName: ${node2}
      containers:
      - name: dvwa
        image: andrefernandes86/c1as-demo-dvwa
        imagePullPolicy: IfNotPresent
        ports: [{ name: http, containerPort: 80, hostPort: 8080 }]
---
apiVersion: v1
kind: Service
metadata:
  name: dvwa-vulnerablewebapp
  namespace: default
spec:
  selector: { app: DVWA_VulnerableWebApp }
  ports: [{ name: http, port: 80, targetPort: 80 }]
  type: ClusterIP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: malware-samples
  namespace: default
  labels: { app: Malware_Samples, app.kubernetes.io/part-of: security-demos }
spec:
  replicas: 1
  selector: { matchLabels: { app: Malware_Samples } }
  template:
    metadata: { labels: { app: Malware_Samples, app.kubernetes.io/part-of: security-demos } }
    spec:
      nodeName: ${node2}
      containers:
      - name: malware-samples
        image: andrefernandes86/tools-malware-samples
        imagePullPolicy: IfNotPresent
        ports: [{ name: http, containerPort: 80, hostPort: 8081 }]
---
apiVersion: v1
kind: Service
metadata:
  name: malware-samples
  namespace: default
spec:
  selector: { app: Malware_Samples }
  ports: [{ name: http, port: 80, targetPort: 80 }]
  type: ClusterIP
YAML
  kubectl -n default rollout status deploy/dvwa-vulnerablewebapp --timeout=180s || true
  kubectl -n default rollout status deploy/malware-samples       --timeout=180s || true
  echo "${OK} Malicious lab deployed."
}
deploy_normal(){
  ensure_openwebui_secret
  cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openwebui
  namespace: default
  labels: { app.kubernetes.io/name: openwebui }
spec:
  replicas: 1
  selector: { matchLabels: { app.kubernetes.io/name: openwebui } }
  template:
    metadata: { labels: { app.kubernetes.io/name: openwebui } }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile: { type: RuntimeDefault }
      initContainers:
      - name: verify-data-dir
        image: busybox:1.36
        command: ["sh","-c","set -e; mkdir -p /app/backend/data && ls -ld /app/backend/data || true"]
        volumeMounts:
          - { name: owui-data, mountPath: /app/backend/data }
      containers:
      - name: openwebui
        image: ghcr.io/open-webui/open-webui:main
        imagePullPolicy: IfNotPresent
        env:
          - { name: OLLAMA_BASE_URL, value: "http://ollama:11434" }
          - name: WEBUI_SECRET_KEY
            valueFrom:
              secretKeyRef:
                name: openwebui-secret
                key: WEBUI_SECRET_KEY
        ports: [{ name: http, containerPort: 8080 }]
        securityContext:
          runAsNonRoot: true
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: false
          capabilities: { drop: ["ALL"] }
        readinessProbe: { httpGet: { path: "/", port: 8080 }, initialDelaySeconds: 5, periodSeconds: 10 }
        livenessProbe:  { httpGet: { path: "/", port: 8080 }, initialDelaySeconds: 15, periodSeconds: 20 }
        resources:
          requests: { cpu: 200m, memory: 256Mi }
          limits:   { cpu: "1",  memory: 1Gi }
        volumeMounts:
          - { name: owui-data, mountPath: /app/backend/data }
      volumes:
        - name: owui-data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: openwebui
  namespace: default
spec:
  selector: { app.kubernetes.io/name: openwebui }
  ports: [{ name: http, port: 80, targetPort: 8080, nodePort: 30080 }]
  type: NodePort
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: default
  labels: { app.kubernetes.io/name: ollama }
spec:
  replicas: 1
  selector: { matchLabels: { app.kubernetes.io/name: ollama } }
  template:
    metadata: { labels: { app.kubernetes.io/name: ollama } }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile: { type: RuntimeDefault }
      containers:
      - name: ollama
        image: ollama/ollama:latest
        imagePullPolicy: IfNotPresent
        env: [{ name: OLLAMA_HOST, value: 0.0.0.0:11434 }]
        ports: [{ name: api, containerPort: 11434 }]
        securityContext:
          runAsNonRoot: true
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: false
          capabilities: { drop: ["ALL"] }
        volumeMounts: [{ name: ollama-data, mountPath: /root/.ollama }]
        readinessProbe: { httpGet: { path: "/api/version", port: 11434 }, initialDelaySeconds: 5, periodSeconds: 10 }
        livenessProbe:  { httpGet: { path: "/api/version", port: 11434 }, initialDelaySeconds: 15, periodSeconds: 20 }
        resources:
          requests: { cpu: 500m, memory: 1Gi }
          limits:   { cpu: "2",  memory: 4Gi }
      volumes: [{ name: ollama-data, emptyDir: {} }]
---
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: default
spec:
  selector: { app.kubernetes.io/name: ollama }
  ports: [{ name: api, port: 11434, targetPort: 11434, nodePort: 31134 }]
  type: NodePort
YAML
  kubectl -n default rollout status deploy/openwebui --timeout=240s || true
  kubectl -n default rollout status deploy/ollama   --timeout=300s || true
  echo "${OK} Normal lab deployed."
}
remove_labs(){
  kdel -n default delete deploy dvwa-vulnerablewebapp malware-samples openwebui ollama --ignore-not-found
  kdel -n default delete svc    dvwa-vulnerablewebapp malware-samples openwebui ollama --ignore-not-found
  echo "${OK} Removed demo labs."
}

# ===================== CLEANUP WIZARD (new) =====================
prompt_yn(){
  local msg="$1" def="${2:-y}" ans
  read -r -p "$msg [${def^^}/$( [ "$def" = "y" ] && echo n || echo y )]: " ans || true
  ans="${ans:-$def}"
  case "${ans,,}" in y|yes) return 0 ;; *) return 1 ;; esac
}
list_leftovers(){
  # Echo a summary of suspected leftovers (no deletes here).
  box "Cleanup — Detected Items"
  echo "Namespaces:"
  kubectl get ns "$NS_CS" "$FS_NS" 2>/dev/null | sed '1d' || true
  echo

  echo "Default namespace (demos/resources):"
  kubectl -n default get deploy dvwa-vulnerablewebapp malware-samples openwebui ollama 2>/dev/null | sed '1d' || true
  kubectl -n default get svc    dvwa-vulnerablewebapp malware-samples openwebui ollama 2>/dev/null | sed '1d' || true
  kubectl -n default get secret openwebui-secret 2>/dev/null | sed '1d' || true
  echo

  echo "Trend Micro scan jobs (any namespace):"
  kubectl get jobs -A 2>/dev/null | awk 'NR==1 || $2 ~ /^trendmicro-scan-job-/' || true
  echo

  echo "TTL enforcer components:"
  kubectl -n "$NS_CS" get cronjob "$TTL_ENF_CJ" 2>/dev/null | sed '1d' || true
  kubectl get clusterrole "$TTL_ENF_CR" 2>/dev/null | sed '1d' || true
  kubectl get clusterrolebinding "$TTL_ENF_CRB" 2>/dev/null | sed '1d' || true
  kubectl -n "$NS_CS" get sa "$TTL_ENF_SA" 2>/dev/null | sed '1d' || true
  echo

  echo "File Security NodePort:"
  kubectl -n "$FS_NS" get svc "$FS_NODEPORT_SVC" 2>/dev/null | sed '1d' || true
  echo

  echo "ICAP port-forward:"
  if [ -f "$PF_PIDFILE" ]; then
    echo "  PID $(cat "$PF_PIDFILE" 2>/dev/null || echo '?') (pidfile: $PF_PIDFILE)"
  else
    echo "  (none)"
  fi
  echo

  echo "Failed/CrashLoop pods (last hour):"
  kubectl get pods -A --field-selector=status.phase!=Running 2>/dev/null | awk 'NR==1 || /CrashLoopBackOff|Error|ImagePullBackOff|Completed/' || true
}
cleanup_wizard(){
  need kubectl
  list_leftovers
  echo
  if prompt_yn "Do you want to run quick clean ALL (safe deletes of demos, scan-jobs TTL, TTL enforcer, secrets, NodePorts, port-forward, failed pods)?" y; then
    cleanup_all_safe
    echo "${OK} Quick clean complete."
    return 0
  fi

  echo
  box "Choose Items to Clean"
  if prompt_yn "• Remove demo Deployments/Services in 'default' (DVWA, Malware, OpenWebUI, Ollama)?" y; then
    remove_labs
  fi

  if prompt_yn "• Stop ICAP port-forward (if running)?" y; then
    icap_pf_stop
  fi

  if prompt_yn "• Remove File Security NodePort Service (${FS_NODEPORT_SVC} in ${FS_NS})?" y; then
    kdel -n "$FS_NS" delete svc "$FS_NODEPORT_SVC" --ignore-not-found
  fi

  if prompt_yn "• Remove OpenWebUI secret (openwebui-secret in default)?" y; then
    kdel -n default delete secret openwebui-secret --ignore-not-found
  fi

  if prompt_yn "• Force TTL on trendmicro-scan-job-* to 1s (fast GC)?" y; then
    cleanup_scan_jobs_now
  fi

  if prompt_yn "• Remove TTL enforcer (CronJob/SA/CR/CRB)?" y; then
    remove_ttl_enforcer
  fi

  if prompt_yn "• Remove Trend Micro namespaces (${NS_CS}, ${FS_NS}) if empty?" n; then
    kdel delete ns "$NS_CS" --ignore-not-found --wait=false
    kdel delete ns "$FS_NS" --ignore-not-found --wait=false
  fi

  if prompt_yn "• Delete FAILED/CrashLoop pods (best effort)?" y; then
    # Delete pods in bad states across all namespaces (won't touch Running)
    set +e
    mapfile -t badpods < <(kubectl get pods -A --no-headers 2>/dev/null | awk '/CrashLoopBackOff|Error|ImagePullBackOff/{print $1":"$2}')
    for ns_pod in "${badpods[@]}"; do
      ns="${ns_pod%%:*}"; pod="${ns_pod##*:}"
      echo "Deleting ${ns}/${pod} ..."
      kdel -n "$ns" delete pod "$pod" --force --grace-period=0
    done
    set -e
  fi

  echo "${OK} Cleanup wizard finished."
}
cleanup_all_safe(){
  # Safe, opinionated cleanup
  remove_labs
  icap_pf_stop
  kdel -n "$FS_NS" delete svc "$FS_NODEPORT_SVC" --ignore-not-found
  kdel -n default delete secret openwebui-secret --ignore-not-found
  cleanup_scan_jobs_now
  remove_ttl_enforcer
  kdel delete ns "$NS_CS" --ignore-not-found --wait=false
  kdel delete ns "$FS_NS" --ignore-not-found --wait=false
  # Delete clearly failed/crashing pods
  set +e
  mapfile -t badpods < <(kubectl get pods -A --no-headers 2>/dev/null | awk '/CrashLoopBackOff|Error|ImagePullBackOff/{print $1":"$2}')
  for ns_pod in "${badpods[@]}"; do
    ns="${ns_pod%%:*}"; pod="${ns_pod##*:}"
    echo "Deleting ${ns}/${pod} ..."
    kdel -n "$ns" delete pod "$pod" --force --grace-period=0
  done
  set -e
}

# ===================== MENUS =====================
main_menu(){
  clear
  box "Trend Micro Demo - Main Menu"
  cat <<MENU
  1) Status
  2) Platform Tools
  q) Quit
MENU
  echo -n "Choose: "
}
platform_tools_menu(){
  clear
  box "PLATFORM TOOLS"
  cat <<MENU
  1) Check status (installed + pods by node)
  2) Container Security
  3) File Security
  4) Show URLs
  5) Validate & Clean Up previous components
  b) Back
MENU
  echo -n "Choose: "
}
container_security_menu(){
  clear
  box "Container Security"
  cat <<MENU
  1) Install/Upgrade Container Security (with TTL enforcer)
  2) Remove Container Security
  3) Deploy Demos (DVWA + Malware, OpenWebUI + Ollama)
  4) Remove Demos
  b) Back
MENU
  echo -n "Choose: "
}
file_security_menu(){
  clear
  box "File Security"
  cat <<MENU
  1) Install/Upgrade File Security (expose via NodePort + TTL enforcer)
  2) Remove File Security
  3) Start ICAP port-forward (0.0.0.0:${PF_LOCAL_ICP} -> svc/*-scanner:${PF_REMOTE_ICP})
  4) Stop  ICAP port-forward
  5) Status ICAP port-forward
  b) Back
MENU
  echo -n "Choose: "
}

# -------- Entry --------
need kubectl; need helm
while true; do
  main_menu
  read -r CAT
  case "${CAT:-}" in
    1) status_check; read -rp $'\n[enter] ' _ ;;
    2)
      while true; do
        platform_tools_menu
        read -r PT
        case "${PT:-}" in
          1) status_check; read -rp $'\n[enter] ' _ ;;
          2)
            while true; do
              container_security_menu
              read -r CSCH
              case "${CSCH:-}" in
                1) install_cs;    read -rp $'\n[enter] ' _ ;;
                2) remove_cs;     read -rp $'\n[enter] ' _ ;;
                3) deploy_malicious; deploy_normal; read -rp $'\n[enter] ' _ ;;
                4) remove_labs;   read -rp $'\n[enter] ' _ ;;
                b|B) break ;;
                *) echo "${WARN} Invalid option" ;;
              esac
            done
            ;;
          3)
            while true; do
              file_security_menu
              read -r FSCH
              case "${FSCH:-}" in
                1) install_fs;      read -rp $'\n[enter] ' _ ;;
                2) remove_fs;       read -rp $'\n[enter] ' _ ;;
                3) icap_pf_start;   read -rp $'\n[enter] ' _ ;;
                4) icap_pf_stop;    read -rp $'\n[enter] ' _ ;;
                5) icap_pf_status;  read -rp $'\n[enter] ' _ ;;
                b|B) break ;;
                *) echo "${WARN} Invalid option" ;;
              esac
            done
            ;;
          4) status_urls; read -rp $'\n[enter] ' _ ;;
          5) cleanup_wizard; read -rp $'\n[enter] ' _ ;;   # NEW
          b|B) break ;;
          *) echo "${WARN} Invalid option" ;;
        esac
      done
      ;;
    q|Q) exit 0 ;;
    *) echo "${WARN} Invalid option" ;;
  esac
done
