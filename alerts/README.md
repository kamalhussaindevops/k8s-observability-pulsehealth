# Alerting & SLO Design

PrometheusRule manifests for the kube-prometheus-stack operator. Each file groups recording rules and alerts for one concern.

## What's in here

| File | Purpose |
| ---- | ------- |
| `slo-availability.yaml` | Ingress availability SLO (99.0% non-5xx over 30 days) with multi-burn-rate alerts |
| `slo-latency.yaml` | Ingress latency SLO (p99 < 250ms) with sustained-violation alerts |
| `infrastructure-alerts.yaml` | Pod/node/storage/ingress operational alerts |

## Design philosophy

**SLO alerts page; infrastructure alerts ticket.**

- SLO alerts (`severity: critical`) represent user-facing problems. They go to whoever is on-call.
- Infrastructure alerts (`severity: warning`) represent operational risk — pod OOMKills, PVC nearing capacity, single node degraded. They open tickets/Slack messages but don't page.

This separation prevents alert fatigue. A pod restart isn't user-impact until it disrupts availability — which the SLO alert already catches.

## SLO alerts use multi-burn-rate

Following the Google SRE Workbook ([chapter 5](https://sre.google/workbook/alerting-on-slos/)), each SLO has two burn-rate alerts:

| Burn rate | Window | Budget consumed in window | Severity | Reasoning |
| --------- | ------ | ------------------------- | -------- | --------- |
| 14.4× | 1 hour | 2% | `critical` (page) | Catches acute outages |
| 6× | 6 hours | 5% | `warning` (ticket) | Catches slow burns |

The math: SLO is `99% over 30 days`, so budget = 1% of requests in 30 days. Burning 2% of *budget* in 1 hour means depleting the entire 30-day budget in `30 days × 24h / (14.4 × 1h) = 50 hours` — i.e., 2 days if the burn continues. That's a page-worthy rate.

The two-window pattern (both `5m` AND `1h` must show high burn) prevents false positives from a single spike. Both windows must agree before firing.

## Apply

These manifests reference `release: kube-prometheus-stack` in their labels — that's the selector the operator uses to discover them. Apply with:

```bash
kubectl apply -f alerts/ -n monitoring
```

Verify Prometheus picked them up:

```bash
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  promtool query instant http://localhost:9090 \
  'slo:ingress_availability_ratio:5m'
```

Should return a value (likely close to 1.0 if no traffic is failing).

## SLO targets in plain language

| SLO | Target | Error budget (per 30 days) |
| --- | ------ | -------------------------- |
| Availability | 99.0% non-5xx | 7h 12min of downtime / 1% of requests |
| Latency | p99 < 250ms for 99% of windows | ~7h of degraded latency |

These are demo-appropriate. Real production SLOs would be derived from product/business requirements — e.g., "checkout flow must complete in <2s for 99% of users."

## Why these specific recording rules

Pre-computing the SLI ratios at multiple windows (`5m`, `1h`, `6h`, `30d`) lets:
- **Dashboards** query a single recording rule (fast, cheap) instead of computing rates ad-hoc
- **Alerts** reference the same numbers dashboards do (consistency)
- **Operators** see the SLI history without writing PromQL

The `slo:` prefix on rule names is a convention from the Google SRE Workbook — it makes it obvious which queries are SLI/SLO related in Grafana's autocomplete.

## What this section deliberately does NOT include

- **Alertmanager routing config** — that lives in the Alertmanager values, not in PrometheusRule. Production deployments route different severities to different receivers (PagerDuty for critical, Slack for warning, email for info).
- **Notification templates** — same reason.
- **Apdex-style satisfaction SLIs** — could be useful, but adds complexity without changing the demo signal.
- **Per-microservice SLOs** — would require each service to emit its own metrics. The Online Boutique manifests aren't instrumented for that.

These are documented as v2 expansions, not gaps.
