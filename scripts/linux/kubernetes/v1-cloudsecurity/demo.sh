#!/usr/bin/env bash
# demo-suite.sh — Menu to manage Trend Micro demos on your K8s lab
# Items:
#  0) Check status (what’s installed + pods by node)
#  1) Remove Container Security
# 11) Install/Upgrade Container Security
#  2) Remove File Security
# 22) Install/Upgrade File Security (auto-expose via NodePort)
#  3) Status board (easy-to-read table)
#  4) Show URLs (remote access & internal)
#  5) Deploy Malicious Lab (DVWA+Malware; fixed hostPorts)
#  6) Deploy Normal Lab (OpenWebUI+Ollama; fixed)
#  7) Remove Malicious & Normal Labs

set -euo pipefail

# -------- Config (edit if needed) --------
REL_CS="trendmicro"                       # Container Security Helm release
NS_CS="trendmicro-system"
CS_CHART_URL="https://github.com/trendmicro/visionone-container-security-helm/archive/main.tar.gz"
OVERRIDES="./overrides.yaml"

FS_NS="visionone-filesecurity"            # File Security
FS_REL_DEFAULT="my-release"
FS_NODEPORT_SVC="v1fs-scanner-nodeport"
FS_NODEPORT=32051                         # external port for gRPC (Pod listens on 50051)

OPENWEBUI_NODEPORT=30080
OLLAMA_NODEPORT=31134

# -------- Styling --------
BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'
RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; CYAN=$'\e[36m'
OK="✅"; WARN="⚠️ "; ERR="❌"; INFO="ℹ️ "
COLS="$(tput cols 2>/dev/null || echo 80)"
hr(){ printf "${DIM}%*s${RESET}\n" "$COLS" | tr ' ' '─'; }
box(){ local t="$1"; hr; printf "${BOLD}${t}${RESET}\n"; hr; }
need(){ command -v "$1" >/dev/null || { echo "${ERR} Missing: $1"; exit 1; } }

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

# -------- Status helpers --------
installed_cs(){ helm status "$REL_CS" -n "$NS_CS" >/dev/null 2>&1 && echo "yes" || echo ""; }
find_fs_release(){
  # Return first release in FS_NS whose chart is visionone-filesecurity/*
  helm list -n "$FS_NS" -o json 2>/dev/null | awk -v IGNORECASE=1 -F'"' '/visionone-filesecurity/ {for(i=1;i<=NF;i++){if($i=="name"){print $(i+2); exit}}}'
}
installed_fs(){ local r; r="$(find_fs_release)"; [ -n "$r" ] && echo "$r" || echo ""; }

# -------- Item 0: Check status (what’s installed + pods by node) --------
item_check_status(){
  need kubectl; need helm
  local master node1 node2
  master="$(detect_master)"; read -r node1 node2 <<<"$(detect_workers "$master")"
  print_nodes_table "$master" "$node1" "$node2"

  box "What’s Installed"
  if [ -n "$(installed_cs)" ]; then
    echo "Container Security: ${GREEN}installed${RESET} (release: ${REL_CS}, ns: ${NS_CS})"
  else
    echo "Container Security: ${YELLOW}not installed${RESET}"
  fi
  local fsrel; fsrel="$(installed_fs)"
  if [ -n "$fsrel" ]; then
    echo "File Security: ${GREEN}installed${RESET} (release: ${fsrel}, ns: ${FS_NS})"
  else
    echo "File Security: ${YELLOW}not installed${RESET}"
  fi

  echo
  box "Pods by Node"
  # the exact loop you provided
  for n in $(kubectl get nodes -o name | cut -d/ -f2); do
    echo "=== $n ==="
    kubectl get pods -A --field-selector spec.nodeName="$n" -o wide
    echo
  done
}

# -------- Item 1/11: Remove/Install Container Security --------
item_remove_cs(){
  echo "${INFO} Uninstalling Container Security (best effort)..."
  helm uninstall "$REL_CS" -n "$NS_CS" || true
  kubectl delete ns "$NS_CS" --wait=false || true
  echo "${OK} Done."
}
item_install_cs(){
  need kubectl; need helm
  echo "== Install/Upgrade Trend Micro Vision One Container Security =="
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

  # backup then write overrides
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
      "$REL_CS" --namespace "$NS_CS" --values "$OVERRIDES" "$CS_CHART_URL"
  else
    echo "Installing new release..."
    helm install "$REL_CS" --namespace "$NS_CS" --create-namespace \
      --values "$OVERRIDES" "$CS_CHART_URL"
  fi

  echo "Waiting for core components..."
  for d in trendmicro-oversight-controller trendmicro-scan-manager trendmicro-policy-operator trendmicro-metacollector trendmicro-admission-controller trendmicro-usage-controller trendmicro-scout; do
    kubectl -n "$NS_CS" rollout status deploy "$d" --timeout=180s || true
  done
  echo "${OK} Container Security ready (check pods in ${NS_CS})."
}

# -------- Item 2/22: Remove/Install File Security (with NodePort) --------
item_remove_fs(){
  echo "${INFO} Uninstalling File Security (best effort)..."
  local rel; rel="$(installed_fs)"; [ -z "$rel" ] && rel="$FS_REL_DEFAULT"
  helm uninstall "$rel" -n "$FS_NS" || true
  kubectl delete ns "$FS_NS" --wait=false || true
  echo "${OK} Done."
}
item_install_fs(){
  need kubectl; need helm
  echo "== Install/Upgrade Trend Vision One — File Security =="
  read -r -p "Paste File Security REGISTRATION TOKEN: " FS_TOKEN
  [ -z "$FS_TOKEN" ] && { echo "Token cannot be empty"; exit 1; }

  kubectl create ns "$FS_NS" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$FS_NS" create secret generic token-secret \
    --from-literal=registration-token="$FS_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$FS_NS" create secret generic device-token-secret \
    --dry-run=client -o yaml | kubectl apply -f -

  helm repo add visionone-filesecurity https://trendmicro.github.io/visionone-file-security-helm/ >/dev/null
  helm repo update >/dev/null
  local rel; rel="$(installed_fs)"; [ -z "$rel" ] && rel="$FS_REL_DEFAULT"
  helm upgrade --install "$rel" visionone-filesecurity/visionone-filesecurity -n "$FS_NS"

  echo "Waiting for scanner to be Ready..."
  kubectl -n "$FS_NS" rollout status deploy "$rel-visionone-filesecurity-scanner" --timeout=300s || true

  # Expose scanner via a dedicated NodePort (persistent, Helm-independent)
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

  echo "${OK} File Security exposed at NodePort ${FS_NODEPORT_SVC}:${FS_NODEPORT}"
}

# -------- Item 3: Status board --------
item_status_board(){
  box "Status Board (pods across cluster)"
  printf "%-16s %-38s %-9s %-10s %-16s %-15s\n" "NAMESPACE" "NAME" "READY" "STATUS" "NODE" "POD-IP"
  hr
  kubectl get pods -A -o wide --no-headers | awk '{printf "%-16s %-38s %-9s %-10s %-16s %-15s\n", $1,$2,$3,$4,$8,$6}'
  echo

  box "Key Namespaces Summary"
  echo "Container Security (${NS_CS}):"
  kubectl -n "$NS_CS" get deploy,ds,po -o wide || true
  echo
  echo "File Security (${FS_NS}):"
  kubectl -n "$FS_NS" get deploy,svc,po -o wide || true
  echo
  echo "Default (demos):"
  kubectl -n default get deploy,svc,po -o wide || true
}

# -------- Item 4: Show URLs --------
item_show_urls(){
  local master node1 node2; master="$(detect_master)"; read -r node1 node2 <<<"$(detect_workers "$master")"
  local node2ip; node2ip="$(node_ip "$node2")"
  local ips; ips="$(node_ips_all)"

  box "Remote & Internal Access URLs"

  echo "${BOLD}Malicious Lab (hostPorts on node2)${RESET}"
  if [ -n "$node2ip" ]; then
    echo "  DVWA_VulnerableWebApp  ->  ${CYAN}http://${node2ip}:8080${RESET}"
    echo "  Malware_Samples        ->  ${CYAN}http://${node2ip}:8081${RESET}"
  else
    echo "  ${WARN}node2 IP not found. Ensure a worker is labeled/selected for hostPorts."
  fi
  echo

  echo "${BOLD}Normal Lab (NodePorts on any node)${RESET}"
  for ip in $ips; do
    kubectl -n default get svc openwebui >/dev/null 2>&1 && \
      echo "  OpenWebUI              ->  ${CYAN}http://${ip}:${OPENWEBUI_NODEPORT}${RESET}"
    kubectl -n default get svc ollama >/dev/null 2>&1 && \
      echo "  Ollama API             ->  ${CYAN}http://${ip}:${OLLAMA_NODEPORT}/api/version${RESET}"
  done
  echo

  echo "${BOLD}Vision One File Security gRPC (NodePort)${RESET}"
  for ip in $ips; do
    kubectl -n "$FS_NS" get svc "$FS_NODEPORT_SVC" >/dev/null 2>&1 && \
      echo "  Scanner                ->  ${CYAN}${ip}:${FS_NODEPORT}${RESET}"
  done
}

# -------- Item 5: Deploy Malicious Lab --------
item_deploy_malicious(){
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

# -------- Item 6: Deploy Normal Lab --------
item_deploy_normal(){
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
      - name: fix-perms
        image: busybox:1.36
        command: ["sh","-c","chmod -R 0777 /data || true"]
        volumeMounts: [{ name: owui-data, mountPath: /data }]
      containers:
      - name: openwebui
        image: ghcr.io/open-webui/open-webui:latest
        imagePullPolicy: IfNotPresent
        env: [{ name: OLLAMA_API_BASE_URL, value: http://ollama:11434 }]
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
        volumeMounts: [{ name: owui-data, mountPath: /app/backend/data }]
      volumes: [{ name: owui-data, emptyDir: {} }]
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

  kubectl -n default rollout status deploy/openwebui --timeout=180s || true
  kubectl -n default rollout status deploy/ollama   --timeout=300s || true
  echo "${OK} Normal lab deployed."
}

# -------- Item 7: Remove labs --------
item_remove_labs(){
  kubectl -n default delete deploy dvwa-vulnerablewebapp malware-samples openwebui ollama --ignore-not-found
  kubectl -n default delete svc    dvwa-vulnerablewebapp malware-samples openwebui ollama --ignore-not-found
  echo "${OK} Removed demo labs."
}

# -------- Menu --------
menu(){
  clear
  box "Trend Micro Demo Menu"
  cat <<MENU
  0) Check status (installed + pods by node)
  1) Remove Container Security
 11) Install/Upgrade Container Security
  2) Remove File Security
 22) Install/Upgrade File Security (expose via NodePort ${FS_NODEPORT})
  3) Status board
  4) Show URLs
  5) Deploy Malicious Lab (DVWA+Malware)
  6) Deploy Normal Lab (OpenWebUI+Ollama)
  7) Remove Malicious & Normal Labs
  q) Quit
MENU
  echo -n "Choose: "
}

# -------- Entry --------
need kubectl; need helm
while true; do
  menu
  read -r CH
  case "${CH:-}" in
    0) item_check_status; read -rp $'\n[enter] ' _ ;;
    1) item_remove_cs;    read -rp $'\n[enter] ' _ ;;
   11) item_install_cs;   read -rp $'\n[enter] ' _ ;;
    2) item_remove_fs;    read -rp $'\n[enter] ' _ ;;
   22) item_install_fs;   read -rp $'\n[enter] ' _ ;;
    3) item_status_board; read -rp $'\n[enter] ' _ ;;
    4) item_show_urls;    read -rp $'\n[enter] ' _ ;;
    5) item_deploy_malicious; read -rp $'\n[enter] ' _ ;;
    6) item_deploy_normal;   read -rp $'\n[enter] ' _ ;;
    7) item_remove_labs;     read -rp $'\n[enter] ' _ ;;
    q|Q) exit 0 ;;
    *) echo "${WARN} Invalid option" ;;
  esac
done
