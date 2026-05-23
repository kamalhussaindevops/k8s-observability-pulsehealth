#!/usr/bin/env bash
# audit-aws-orphans.sh — Find AWS resources that may be costing money
#
# Audits both ELB APIs (v1 + v2), ENIs, security groups, EBS volumes, and
# Elastic IPs in a given VPC (or globally if no VPC specified). Especially
# useful AFTER a terraform destroy to confirm nothing is left over, OR
# BEFORE a terraform destroy to see what's about to block it.
#
# Why both ELB APIs:
#   - elbv2  lists Application Load Balancers and Network Load Balancers
#   - elb    lists Classic Load Balancers (the un-annotated Service default)
# Audits that only check one miss the most common kind of orphan.
#
# Usage:
#   ./audit-aws-orphans.sh                    # global audit
#   ./audit-aws-orphans.sh -v vpc-0abc123     # scope to one VPC
#   REGION=us-east-1 ./audit-aws-orphans.sh   # different region

set -euo pipefail

: "${REGION:=ap-south-1}"
VPC_FILTER=""

while getopts "v:" opt; do
  case "$opt" in
    v) VPC_FILTER=$OPTARG ;;
    *) echo "Usage: $0 [-v vpc-id]"; exit 1 ;;
  esac
done

header() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
ok()     { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
found()  { printf '  \033[1;33m⚠\033[0m %s\n' "$*"; }

# Filter helper
vpc_arg_v2() { [[ -n "$VPC_FILTER" ]] && echo "?VpcId=='$VPC_FILTER'" || echo ""; }
vpc_arg_v1() { [[ -n "$VPC_FILTER" ]] && echo "?VPCId=='$VPC_FILTER'" || echo ""; }

# --- EC2 instances ---
header "EC2 instances (running/pending/stopping)"
FILTER="Name=instance-state-name,Values=running,pending,stopping"
[[ -n "$VPC_FILTER" ]] && FILTER="$FILTER Name=vpc-id,Values=$VPC_FILTER"
RESULT=$(aws ec2 describe-instances --region "$REGION" \
  --filters $FILTER \
  --query "Reservations[].Instances[].[InstanceId,InstanceType,State.Name]" \
  --output text)
if [[ -n "$RESULT" ]]; then
  found "Found:"
  echo "$RESULT" | column -t
else
  ok "None"
fi

# --- Network Load Balancers and ALBs ---
header "NLB / ALB (elbv2)"
QUERY="LoadBalancers[$(vpc_arg_v2)].[LoadBalancerName,Type,State.Code,DNSName]"
RESULT=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "$QUERY" --output text)
if [[ -n "$RESULT" ]]; then
  found "Found:"
  echo "$RESULT" | column -t
else
  ok "None"
fi

# --- Classic Load Balancers ---
header "Classic Load Balancers (elb)"
QUERY="LoadBalancerDescriptions[$(vpc_arg_v1)].[LoadBalancerName,VPCId,DNSName]"
RESULT=$(aws elb describe-load-balancers --region "$REGION" \
  --query "$QUERY" --output text)
if [[ -n "$RESULT" ]]; then
  found "Found (these are most often missed by 'elbv2' checks):"
  echo "$RESULT" | column -t
else
  ok "None"
fi

# --- Network Interfaces ---
header "Network Interfaces (ENIs)"
if [[ -n "$VPC_FILTER" ]]; then
  RESULT=$(aws ec2 describe-network-interfaces --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_FILTER" \
    --query "NetworkInterfaces[].[NetworkInterfaceId,Status,Description]" \
    --output text)
else
  RESULT=$(aws ec2 describe-network-interfaces --region "$REGION" \
    --filters "Name=status,Values=available" \
    --query "NetworkInterfaces[].[NetworkInterfaceId,Status,Description]" \
    --output text)
fi
if [[ -n "$RESULT" ]]; then
  found "Found:"
  echo "$RESULT" | column -t
else
  ok "None"
fi

# --- EBS Volumes (available = unattached) ---
header "EBS Volumes (available/unattached — paid for, doing nothing)"
RESULT=$(aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=status,Values=available" \
  --query "Volumes[].[VolumeId,Size,VolumeType,CreateTime]" \
  --output text)
if [[ -n "$RESULT" ]]; then
  found "Found:"
  echo "$RESULT" | column -t
else
  ok "None"
fi

# --- Security Groups (non-default, in VPC if scoped) ---
if [[ -n "$VPC_FILTER" ]]; then
  header "Security Groups in $VPC_FILTER (excluding default)"
  RESULT=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_FILTER" \
    --query "SecurityGroups[?GroupName!='default'].[GroupId,GroupName,Description]" \
    --output text)
  if [[ -n "$RESULT" ]]; then
    found "Found:"
    echo "$RESULT" | column -t
  else
    ok "None (only default SG)"
  fi
fi

# --- NAT Gateways ---
header "NAT Gateways"
QUERY="NatGateways[].[NatGatewayId,State,VpcId]"
[[ -n "$VPC_FILTER" ]] && \
  RESULT=$(aws ec2 describe-nat-gateways --region "$REGION" \
    --filter "Name=vpc-id,Values=$VPC_FILTER" \
    --query "$QUERY" --output text) || \
  RESULT=$(aws ec2 describe-nat-gateways --region "$REGION" \
    --query "$QUERY" --output text)
if [[ -n "$RESULT" ]]; then
  found "Found:"
  echo "$RESULT" | column -t
else
  ok "None"
fi

# --- Elastic IPs ---
header "Elastic IPs (charged when unattached)"
RESULT=$(aws ec2 describe-addresses --region "$REGION" \
  --query "Addresses[].[PublicIp,AssociationId,InstanceId]" \
  --output text)
if [[ -n "$RESULT" ]]; then
  found "Found:"
  echo "$RESULT" | column -t
else
  ok "None"
fi

# --- EKS clusters ---
header "EKS Clusters"
RESULT=$(aws eks list-clusters --region "$REGION" --query "clusters[]" --output text)
if [[ -n "$RESULT" ]]; then
  found "Found: $RESULT"
else
  ok "None"
fi

echo ""
echo "Audit complete. Anything flagged with ⚠ may be costing money."
