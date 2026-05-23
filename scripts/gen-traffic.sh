#!/usr/bin/env bash
# gen-traffic.sh — Generate realistic traffic against the Online Boutique NLB
#
# Used during the screenshot capture phase to populate Grafana dashboards
# with non-flat curves. Hits a mix of endpoints (homepage, product pages,
# cart) with 4 parallel requests per cycle and small jitter between cycles.
#
# Usage:
#   ./gen-traffic.sh                     # auto-detect NLB hostname, run forever
#   ./gen-traffic.sh -d 300              # run for 300 seconds
#   ./gen-traffic.sh -h <hostname>       # use specific hostname (skip auto-detect)
#   ./gen-traffic.sh -d 600 -p 8         # 600s with 8 parallel requests per cycle
#
# Stops cleanly on Ctrl-C (kills all child curls).

set -euo pipefail

# Defaults
DURATION=0      # 0 = forever
PARALLEL=4
HOST=""
ENDPOINTS=(
  "/"
  "/product/OLJCESPC7Z"
  "/product/66VCHSJNUP"
  "/product/1YMWWN1N4O"
  "/cart"
)

while getopts "d:p:h:" opt; do
  case "$opt" in
    d) DURATION=$OPTARG ;;
    p) PARALLEL=$OPTARG ;;
    h) HOST=$OPTARG ;;
    *) echo "Usage: $0 [-d seconds] [-p parallelism] [-h hostname]"; exit 1 ;;
  esac
done

# Auto-detect NLB hostname if not provided
if [[ -z "$HOST" ]]; then
  echo "Detecting NLB hostname..."
  HOST=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  [[ -z "$HOST" ]] && { echo "Could not auto-detect; pass with -h"; exit 1; }
fi

echo "Target:      http://$HOST/"
echo "Parallelism: $PARALLEL requests per cycle"
if [[ "$DURATION" -eq 0 ]]; then
  echo "Duration:    forever (Ctrl-C to stop)"
else
  echo "Duration:    ${DURATION}s"
fi
echo "Endpoints:   ${#ENDPOINTS[@]} paths"
echo ""

# Trap Ctrl-C: kill all child curls cleanly
cleanup() {
  echo ""
  echo "Stopping. Killing background curls..."
  jobs -p | xargs -r kill 2>/dev/null || true
  wait 2>/dev/null || true
  echo "Done."
  exit 0
}
trap cleanup INT TERM

# Stats
START=$(date +%s)
CYCLES=0
ERRORS=0

# Main loop
while true; do
  for ((i=0; i<PARALLEL; i++)); do
    EP="${ENDPOINTS[$((RANDOM % ${#ENDPOINTS[@]}))]}"
    curl -s -o /dev/null -w "%{http_code}\n" "http://${HOST}${EP}" \
      | grep -qE '^(2|3)' || ERRORS=$((ERRORS + 1)) &
  done
  wait
  CYCLES=$((CYCLES + 1))

  # Progress every 10 cycles
  if (( CYCLES % 10 == 0 )); then
    ELAPSED=$(($(date +%s) - START))
    RATE=$(echo "scale=1; $CYCLES * $PARALLEL / $ELAPSED" | bc)
    printf "[%4ds] cycles=%d  requests=%d  errors=%d  rate=%s req/s\n" \
      "$ELAPSED" "$CYCLES" "$((CYCLES * PARALLEL))" "$ERRORS" "$RATE"
  fi

  # Check duration
  if [[ "$DURATION" -gt 0 ]]; then
    ELAPSED=$(($(date +%s) - START))
    [[ "$ELAPSED" -ge "$DURATION" ]] && break
  fi

  sleep 0.2
done

cleanup
