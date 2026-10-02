#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║   HYBE Fan Platform — Cluster Bootstrap Script                               ║
# ║   Run ONCE after: terraform apply                                            ║
# ║   Sets up: kubeconfig, ArgoCD project + app, verifies HPA readiness          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

CLUSTER_NAME="${CLUSTER_NAME:-hybe-fan-platform-prod}"
REGION="${AWS_REGION:-ap-northeast-2}"
NAMESPACE="hybe-prod"

log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "${RED}✖${NC} $*"; exit 1; }

# ── Preflight checks ───────────────────────────────────────────────────────────
log "Checking required tools..."
for tool in aws kubectl helm argocd; do
  command -v "$tool" &>/dev/null || fail "$tool is not installed. Run: brew install $tool"
  ok "$tool found"
done

# ── Step 1: Configure kubeconfig ──────────────────────────────────────────────
log "Step 1/8 - Configuring kubeconfig for EKS cluster: ${CLUSTER_NAME}"
aws eks update-kubeconfig \
  --region "${REGION}" \
  --name   "${CLUSTER_NAME}" \
  --alias  "hybe-prod"
ok "kubeconfig updated"

# ── Step 2: Verify cluster is healthy ─────────────────────────────────────────
log "Step 2/8 - Verifying EKS cluster health..."
kubectl cluster-info || fail "Cannot reach EKS API server"

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c Ready || true)
if [[ "${NODE_COUNT}" -lt 2 ]]; then
  fail "Expected ≥2 Ready nodes, found ${NODE_COUNT}. Check Terraform node group."
  fi
  ok " Cluster healthy - ${NODE_COUNT} NODES Ready"

  # ── Step 3: Verify Matrics Server (required for HPA) ─────────────────────────
  log "Step 3/8 - Verifying Metrics Server (HPA dependency)..."
  MAX_WAIT=120; WAITED=0
  until kubectl top nodes &>/dev/null; do
    sleep 5; WAITED=$((WAITED+5))
    [[ $WAITED -ge $MAX_WAIT ]] && fail "Metrics Server not ready after ${MAX_WAIT}s"
    warn "Waiting for Matrics Server... (${WAITED}s)"
  done
  ok "Metrics Server is ready - HPA can function"

  # ── Step 4: Create application namespace ─────────────────────────────────────
  log "Step 4/8 - Setting up namespace: ${NAMESPACE}"
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "${NAMESPACE}" environment=production --overwrite
  ok "Namespace ${NAMESPACE} ready"
  
  # ── Step 5: Create ClusterSecretStore for External Secrets Operator ───────────
  log "Step 5/8 - Configuring External Secrets Operator..."
  cat <<EOF | kubectl apply -f -
  apiVersion: external-secrets.io/v1beta1
  kind: ClusterSecretsStore
  metadata:
    name: aws-secrets-manager
  spec:
    provider:
      aws:
        service: SecretsManager
        region: ${REGION}
        auth:
          jwt:
            serviceAccountRef:
              name: external-secrets
              namespace: external-secrets
EOF
ok "ClusterSecretStore configured"

# ── Step 6: Wait for ArgoCD to be ready ──────────────────────────────────────
log "Step 6/8 - Waiting for ArgoCD to be ready..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
ok "ArgoCD server ready"

# Get ArgoCD admin password
ARGOCD_PASSWORD=$(
  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d
)

# Login to ArgoCD
ARGOCD_SERVER=$(
  kubectl -n argocd get svc argocd-server \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "localhost:8080"
)
argocd login "${ARGOCD_SERVER}" \
  --username admin \
  --password "${ARGOCD_PASSWORD}" \
  --grpc-web --insecure 2>/dev/null || \
warn "ArgoCD CLI login failed - use port-forward: kubectl port-forward svc/argocd-server -n argocd 8080:443"

ok "ArgoCD ready - admin password: ${ARGOCD_PASSWORD}"

# ── Step 7: Apply ArgoCD Project + Application (GitOps engine ON) ─────────────
log "Steo 7/8 - Applying ArgoCD Project and Application manifests..."
kubectl apply -f argocd/project.yaml
sleep 3
kubectl apply -f argocd/application.yaml
ok "ArgoCD Application created - GitOps is LIVE"

# Trigger initial sync
argocd app sync hybe-fan-platform --grpc-web 2>/dev/null || \
  warn "Manual sync failed (CLI auth issue) - ArgoCD will auto-sync within 3 minutes"

# ── Step 8: Verify HPA is created and functional ──────────────────────────────
log "Step 8/8 - Verifying Horizontal Pod Autoscalers..."
sleep 30  # Give ArgoCD time to apply resources

for HPA in ticket-service-hpa merch-service-hpa api-gateway-hpa; do
  if kubectl get hpa "${HPA}" -n "${NAMESPACE}" &>/dev/null; then
    ok "HPA ${HPA} found"
    kubectl get hpa "${HPA}" -n "${NAMESPACE}"
  else
    warn "HPA ${HPA} not yet created - ArgoCD may still be syncing"
  fi
done

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   🎤  HYBE Fan Platform Bootstrap Complete!              ║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC}  ArgoCD UI:   kubectl port-forward svc/argocd-server \\  ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}               -n argocd 8080:443                        ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  Password:    ${ARGOCD_PASSWORD}                          ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  Watch HPA:   kubectl get hpa -n ${NAMESPACE} -w        ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  Load test:   k6 run k6/load-test.js                    ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
