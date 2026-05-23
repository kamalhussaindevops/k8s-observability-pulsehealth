#!/usr/bin/env bash
# verify-deploy.sh — Post-deployment health check
#
# Walks the full stack and confirms each layer is healthy. Useful after
# ./deploy.sh, after a long break, or whenever you suspect something drifted.
#
# Checks:
#   1. kubectl context points at the EKS cluster (not kind)
#   2. All nodes Ready
#   3. All pods in monitoring, ingress-nginx, online-boutique Running
#   4. PVCs all Bound
#   5. NLB hostname assigned and resolving
#   6. NLB returns HTTP 200 from the homepage
#   7. Prometheus ServiceMonitor target for ingress-nginx is UP
#
# Exits non-zero if any check fails. Safe to use in CI.

set -uo pipefail   # no -e: we want all checks to run even if one fails

PASS=0
FAIL=0

check() {
  local name=$1
  local cmd=$2
  local expected=$3

  RESULT=$(eval "$cmd" 2>&1) || true
  if echo "$RESULT" | grep -qE "$expected"; then
    printf '\033[1;32m  ✓\033[0m %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '\033[1;31m  ✗\033[0m %s\n' "$name"
    printf '    expected to match: %s\n' "$expected"
    printf '    actual: %s\n' "${RESULT:0:200}"
    FAIL=$((FAIL + 1))
  fi
}

echo "PulseHealth deployment health check"
echo "===================================="
echo ""

# 1. Correct cluster context
check "kubectl context is EKS" \
  "kubectl config current-context" \
  "eks.*pulsehealth"

# 2. Nodes ready
check "All nodes Ready" \
  "kubectl get nodes --no-headers" \
  "Ready"

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
check "Node count is 2" "echo $NODE_COUNT" "^2$"

# 3. Pods running by namespace
for ns in monitoring ingress-nginx online-boutique kube-system; do
  NOT_READY=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
    | awk '$3 != "Running" && $3 != "Completed" {print}' | wc -l)
  check "All pods Running in $ns" "echo $NOT_READY" "^0$"
done

# 4. PVCs bound
UNBOUND=$(kubectl get pvc -A --no-headers 2>/dev/null \
  | awk '$4 != "Bound" {print}' | wc -l)
check "All PVCs Bound" "echo $UNBOUND" "^0$"

# 5. NLB hostname assigned
NLB=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
check "NLB hostname assigned" "echo $NLB" "elb.*amazonaws.com"

# 6. NLB returning 200 on homepage
if [[ -n "$NLB" ]]; then
  check "NLB returns HTTP 200 on /" \
    "curl -s -o /dev/null -w '%{http_code}' http://$NLB/" \
    "^200$"
fi

# 7. Prometheus targets — ingress-nginx UP
# Note: this requires Prometheus to be reachable. Uses an ephemeral pod.
if kubectl get svc -n monitoring kube-prometheus-stack-prometheus >/dev/null 2>&1; then
  TARGETS=$(kubectl run -n monitoring prom-check-$$ \
    --image=curlimages/curl --restart=Never --rm -i --quiet -- \
    curl -s "http://kube-prometheus-stack-prometheus:9090/api/v1/targets" 2>/dev/null || echo "")
  check "ingress-nginx ServiceMonitor target UP" \
    "echo '$TARGETS'" \
    'ingress-nginx-controller.*"health":"up"'
fi

# Summary
echo ""
echo "===================================="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
