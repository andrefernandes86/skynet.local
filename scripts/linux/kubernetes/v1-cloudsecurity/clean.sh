#!/usr/bin/env bash
# clean-trend.sh — best-effort full cleanup for Trend Micro components on this cluster
# - Deletes all trendmicro scan Jobs and their Pods
# - Uninstalls Container Security (trendmicro-system) and File Security (visionone-filesecurity)
# - Removes NodePort for File Security, TTL enforcer, webhooks, CRDs, RBAC
# - Prints verification/status at the end

set -euo pipefail

NS_CS="trendmicro-system"
REL_CS="trendmicro"
NS_FS="visionone-filesecurity"
FS_NODEPORT_SVC="v1fs-scanner-nodeport"

info(){ echo -e "ℹ️  $*"; }
ok(){   echo -e "✅ $*"; }
warn(){ echo -e "⚠️  $*"; }
err(){  echo -e "❌ $*"; }

need(){ command -v "$1" >/dev/null || { err "Missing: $1"; exit 1; } }
need kubectl
need helm

hr(){ printf "%*s\n" "$(tput cols 2>/dev/null || echo 80)" | tr ' ' '-'; }

echo
hr
echo "Trend cleanup — starting"
hr

# 0) Show what we're about to clean (for visibility)
info "Listing Trend-related resources BEFORE cleanup (for context):"
kubectl get all -A 2>/dev/null | egrep -i 'trendmicro|visionone|container-security|filesecurity' || true
echo

# 1) Kill scan jobs (cluster-wide)
info "Patching/deleting trendmicro scan Jobs (cluster-wide)..."
# Patch TTL so finished jobs disappear quickly
kubectl get jobs -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' \
| awk -F'\t' '$2 ~ /^trendmicro-scan-job-/' \
| while IFS=$'\t' read -r ns name; do
    kubectl -n "$ns" patch job "$name" --type=merge -p '{"spec":{"ttlSecondsAfterFinished":1}}' >/dev/null 2>&1 || true
  done

# Delete any jobs still present (force, best effort)
kubectl get jobs -A | awk '/trendmicro-scan-job-/{print $1, $2}' \
| while read -r ns name; do
    kubectl -n "$ns" delete job "$name" --ignore-not-found --force --grace-period=0 >/dev/null 2>&1 || true
  done

# Delete lingering Pods of those jobs
kubectl get pods -A | awk '/trendmicro-scan-job-/{print $1, $2}' \
| while read -r ns pod; do
    kubectl -n "$ns" delete pod "$pod" --force --grace-period=0 >/dev/null 2>&1 || true
  done
ok "Scan jobs cleaned."

# 2) Remove File Security first (often the source of scan jobs)
info "Removing File Security Helm releases (ns=${NS_FS})..."
# Uninstall any Helm releases in the FS namespace
helm list -n "${NS_FS}" -q 2>/dev/null | while read -r rel; do
  [ -n "$rel" ] && helm uninstall "$rel" -n "${NS_FS}" || true
done

# Delete our NodePort service (chart-independent)
kubectl -n "${NS_FS}" delete svc "${FS_NODEPORT_SVC}" --ignore-not-found

# Drop the namespace
kubectl delete ns "${NS_FS}" --ignore-not-found --wait=false || true
ok "File Security removed (best effort)."

# 3) Remove Container Security
info "Removing Container Security Helm release (${REL_CS}) in ns=${NS_CS}..."
helm uninstall "${REL_CS}" -n "${NS_CS}" || true

# Remove TTL enforcer we may have installed
kubectl -n "${NS_CS}" delete cronjob scanjob-ttl-enforcer --ignore-not-found
kubectl delete clusterrolebinding scanjob-ttl-enforcer --ignore-not-found
kubectl delete clusterrole scanjob-ttl-enforcer --ignore-not-found
kubectl -n "${NS_CS}" delete serviceaccount scanjob-ttl-enforcer --ignore-not-found

# Drop the namespace
kubectl delete ns "${NS_CS}" --ignore-not-found --wait=false || true
ok "Container Security removed (best effort)."

# 4) Clean leftover webhooks that could block Pod creation/deletion
info "Removing leftover Admission webhooks referencing Trend components..."
kubectl get mutatingwebhookconfigurations -o name 2>/dev/null | egrep -i 'trend|visionone|container|security' \
  | xargs -r kubectl delete >/dev/null 2>&1 || true
kubectl get validatingwebhookconfigurations -o name 2>/dev/null | egrep -i 'trend|visionone|container|security' \
  | xargs -r kubectl delete >/dev/null 2>&1 || true
ok "Admission webhooks cleaned."

# 5) Clean CRDs (if any were installed)
info "Removing leftover Trend-related CRDs..."
kubectl get crds -o name 2>/dev/null | egrep -i 'trend|container-security|filesecurity|visionone' \
  | xargs -r kubectl delete >/dev/null 2>&1 || true
ok "CRDs cleaned."

# 6) Clean cluster RBAC with Trend identifiers (best effort)
info "Removing leftover ClusterRoles / Bindings with Trend identifiers..."
kubectl get clusterrole -o name 2>/dev/null | egrep -i 'trend|visionone|container|security' \
  | xargs -r kubectl delete >/dev/null 2>&1 || true
kubectl get clusterrolebinding -o name 2>/dev/null | egrep -i 'trend|visionone|container|security' \
  | xargs -r kubectl delete >/dev/null 2>&1 || true
ok "RBAC cleaned."

# 7) Final sweep of any trend pods that might still linger (rare)
info "Deleting any remaining Trend pods (cluster-wide, best effort)..."
kubectl get pods -A | egrep -i 'trendmicro|visionone|container-security|filesecurity' | awk '{print $1, $2}' \
  | while read -r ns pod; do
      kubectl -n "$ns" delete pod "$pod" --force --grace-period=0 >/dev/null 2>&1 || true
    done
ok "Final pod sweep complete."

# 8) Verify
echo
hr
echo "Verification"
hr
echo "Namespaces (trend-related should be gone or Terminating only temporarily):"
kubectl get ns | egrep -i 'trend|visionone' || echo "  none"
echo

echo "Residual Trend resources (should be none):"
kubectl get all -A 2>/dev/null | egrep -i 'trendmicro|visionone|container-security|filesecurity' || echo "  none"
echo

echo "Pods by node (spot check):"
for n in $(kubectl get nodes -o name | cut -d/ -f2); do
  echo "=== $n ==="
  kubectl get pods -A --field-selector spec.nodeName="$n" -o wide
  echo
done

ok "Trend cleanup — completed."
