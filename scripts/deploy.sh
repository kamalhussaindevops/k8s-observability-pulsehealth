#!/usr/bin/env bash
# deploy.sh — End-to-end deployment of PulseHealth observability stack on EKS
#
# Runs the complete sequence:
#   1. Terraform apply (VPC + EKS + IRSA + EBS CSI addon)
#   2. Configure kubectl
#   3. Apply default gp3 StorageClass
#   4. Install kube-prometheus-stack via Helm
#   5. Install ingress-nginx via Helm (provisions NLB)
#   6. Deploy Online Boutique
#   7. Apply application + Grafana Ingress
#   8. Print access URLs
#
# Usage:   ./deploy.sh
# Requires: terraform, kubectl, helm, aws CLI v2, dig
# Idempotent: safe to re-run; uses `helm upgrade --install`

set -euo pipefail

# --- Config (override via env) ---
: "${REGION:=ap-south-1}"
: "${CLUSTER_NAME:=pulsehealth}"
: "${REPO_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"

# --- Pretty output helpers ---
log()  { printf '\033[1;34m[%(%H:%M:%S)T]\033[0m %s\n' -1 "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m  ✗\033[0m %s\n' "$*" >&2; exit 1; }

# --- Preflight ---
log "Preflight checks"
for cmd in terraform kubectl helm aws dig; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: $cmd"
done
ok "All required tools present"

aws sts get-caller-identity >/dev/null 2>&1 || fail "AWS credentials not configured"
ok "AWS credentials OK"

# --- 1. Terraform apply ---
log "Step 1/8: Provisioning AWS infrastructure (~15 min)"
pushd "$REPO_ROOT/platform/terraform" >/dev/null
terraform init -upgrade
terraform apply -auto-approve
popd >/dev/null
ok "Infrastructure provisioned"

# --- 2. Configure kubectl ---
log "Step 2/8: Configuring kubectl"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
kubectl wait --for=condition=Ready nodes --all --timeout=5m
ok "Cluster reachable, nodes Ready"

# --- 3. Default StorageClass ---
log "Step 3/8: Setting gp3 as default StorageClass"
kubectl apply -f "$REPO_ROOT/platform/storage/gp3-storageclass.yaml"
kubectl patch storageclass gp2 \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
  >/dev/null 2>&1 || true
ok "gp3 set as default"

# --- 4. kube-prometheus-stack ---
log "Step 4/8: Installing kube-prometheus-stack (~5 min)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --values "$REPO_ROOT/platform/kube-prometheus-stack/values-eks.yaml" \
  --wait --timeout 10m
ok "Observability stack ready"

# --- 5. ingress-nginx ---
log "Step 5/8: Installing ingress-nginx (~3 min for NLB provisioning)"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --values "$REPO_ROOT/platform/ingress-nginx/values-eks.yaml" \
  --wait --timeout 5m
ok "Ingress controller ready, NLB provisioning"

# --- 6. Online Boutique ---
log "Step 6/8: Deploying Online Boutique"
kubectl create namespace online-boutique --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$REPO_ROOT/apps/online-boutique/kubernetes-manifests.yaml" -n online-boutique
kubectl wait --for=condition=available -n online-boutique deployment --all --timeout=5m
ok "Online Boutique pods Running"

# --- 7. Ingress resources ---
log "Step 7/8: Applying Ingress resources"
kubectl apply -f "$REPO_ROOT/apps/online-boutique/ingress-eks.yaml"

# Grafana ingress requires the NLB IP injected dynamically
NLB_HOST=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
[[ -z "$NLB_HOST" ]] && fail "NLB hostname not yet assigned; rerun in 60 seconds"

NLB_IP=$(dig +short "$NLB_HOST" | head -1)
[[ -z "$NLB_IP" ]] && fail "Could not resolve NLB DNS to IP"

# Render and apply Grafana Ingress with the current NLB IP
sed "s|grafana\..*\.nip\.io|grafana.${NLB_IP}.nip.io|" \
  "$REPO_ROOT/apps/grafana-public-access/ingress-eks.yaml" \
  | kubectl apply -f -
ok "Ingress resources applied"

# --- 8. Print access info ---
log "Step 8/8: Deployment complete"
GRAFANA_PASS=$(kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d)

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║  PulseHealth observability stack is live                                  ║"
echo "╠══════════════════════════════════════════════════════════════════════════╣"
printf "║  Online Boutique:  http://%-46s ║\n" "$NLB_HOST/"
printf "║  Grafana:          http://grafana.%-40s ║\n" "${NLB_IP}.nip.io/"
echo "║                                                                          ║"
echo "║  Grafana login:    admin / $GRAFANA_PASS"
echo "║                                                                          ║"
echo "║  Cost reminder:    ~\$7/day. Run ./destroy-safe.sh when done.             ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
