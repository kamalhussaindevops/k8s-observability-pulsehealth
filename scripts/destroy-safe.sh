#!/usr/bin/env bash
# destroy-safe.sh — Production-correct teardown of PulseHealth EKS stack
#
# Runs the *correct* destroy sequence so terraform doesn't choke on
# Kubernetes-owned cloud resources (orphan LoadBalancers, EBS volumes, ENIs).
#
#   1. Delete LoadBalancer Services (triggers cloud-controller-manager to remove LBs)
#   2. Delete PVCs (triggers EBS CSI to remove volumes)
#   3. Wait for AWS to actually finish (async)
#   4. Audit the VPC for orphans
#   5. terraform destroy
#   6. Final AWS audit
#
# Background: a plain `terraform destroy` strands NLBs, CLBs, ENIs, EBS volumes,
# and security groups when LoadBalancer Services / PVCs aren't deleted first.
# See ../LESSONS.md and ../DESTROY-RUNBOOK.md.
#
# Usage:   ./destroy-safe.sh
# Requires: terraform, kubectl, aws CLI v2

set -euo pipefail

: "${REGION:=ap-south-1}"
: "${REPO_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"

log()  { printf '\033[1;34m[%(%H:%M:%S)T]\033[0m %s\n' -1 "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ⚠\033[0m %s\n' "$*"; }

# --- Confirmation ---
echo "This will destroy the entire PulseHealth EKS cluster and all AWS resources."
read -rp "Type 'destroy' to confirm: " confirm
[[ "$confirm" == "destroy" ]] || { echo "Aborted."; exit 1; }

# --- 1. Delete LoadBalancer Services ---
log "Step 1/6: Deleting LoadBalancer Services (frees up NLBs/CLBs)"
kubectl delete svc -A --field-selector spec.type=LoadBalancer --ignore-not-found
ok "LoadBalancer Services deletion queued"

# --- 2. Delete PVCs ---
log "Step 2/6: Deleting PersistentVolumeClaims (frees up EBS volumes)"
kubectl delete pvc --all -A --ignore-not-found
ok "PVC deletion queued"

# --- 3. Wait for cloud-side cleanup ---
log "Step 3/6: Waiting 180 seconds for AWS-side cleanup (cloud-controller-manager is async)"
sleep 180
ok "Wait complete"

# --- 4. Audit orphans BEFORE terraform destroy ---
log "Step 4/6: Auditing VPC for orphan resources"
VPC=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Name,Values=*pulsehealth*" \
  --query "Vpcs[0].VpcId" --output text 2>/dev/null || echo "None")

if [[ "$VPC" == "None" || "$VPC" == "null" ]]; then
  warn "No VPC found — already destroyed?"
else
  echo "  VPC: $VPC"

  # Classic LBs (most common orphan source)
  ORPHAN_CLBS=$(aws elb describe-load-balancers --region "$REGION" \
    --query "LoadBalancerDescriptions[?VPCId=='$VPC'].LoadBalancerName" --output text)
  if [[ -n "$ORPHAN_CLBS" ]]; then
    warn "Classic LBs still in VPC: $ORPHAN_CLBS"
    for clb in $ORPHAN_CLBS; do
      log "  Deleting orphan CLB: $clb"
      aws elb delete-load-balancer --region "$REGION" --load-balancer-name "$clb"
    done
    log "  Waiting 60s for CLB ENI cleanup"
    sleep 60
  else
    ok "No orphan Classic LBs"
  fi

  # ALBs / NLBs
  ORPHAN_LBS=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?VpcId=='$VPC'].LoadBalancerArn" --output text)
  if [[ -n "$ORPHAN_LBS" ]]; then
    warn "ALBs/NLBs still in VPC: $ORPHAN_LBS"
    for arn in $ORPHAN_LBS; do
      log "  Deleting orphan LB: $arn"
      aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$arn"
    done
    log "  Waiting 60s for ENI cleanup"
    sleep 60
  else
    ok "No orphan ALBs/NLBs"
  fi
fi

# --- 5. Terraform destroy ---
log "Step 5/6: Running terraform destroy"
pushd "$REPO_ROOT/platform/terraform" >/dev/null
terraform destroy -auto-approve
popd >/dev/null
ok "Terraform destroy completed"

# --- 6. Final verification ---
log "Step 6/6: Final AWS verification"
echo ""
echo "=== EC2 instances ==="
aws ec2 describe-instances --region "$REGION" \
  --filters "Name=instance-state-name,Values=running,pending,stopping" \
  --query "Reservations[].Instances[].[InstanceId,InstanceType]" --output text || true

echo "=== ALB/NLB ==="
aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[].[LoadBalancerName]" --output text || true

echo "=== Classic LBs ==="
aws elb describe-load-balancers --region "$REGION" \
  --query "LoadBalancerDescriptions[].[LoadBalancerName]" --output text || true

echo "=== EBS volumes (available) ==="
aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=status,Values=available" \
  --query "Volumes[].[VolumeId,Size]" --output text || true

echo "=== EKS clusters ==="
aws eks list-clusters --region "$REGION" --output text || true

echo ""
ok "All outputs above should be blank. If anything appears, run ./audit-aws-orphans.sh"
echo ""
log "Destroy complete. Meter is at \$0/hr."
