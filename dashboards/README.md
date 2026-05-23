# Grafana Dashboards

Custom dashboards for the PulseHealth observability stack. These complement (don't replace) the ~25 pre-built dashboards that ship with kube-prometheus-stack.

## What's in here

| File | Purpose |
| ---- | ------- |
| `pulsehealth-slo-overview.json` | Single-pane SLO view: availability SLI, latency p99, error budget, request rate, status code breakdown |

## Design philosophy

The pre-built dashboards from kube-prometheus-stack are excellent for *infrastructure* observability (nodes, pods, namespaces, networking). They're noisy for *service-level* observability — too many panels, too much scope.

`pulsehealth-slo-overview.json` is the opposite: small, focused, SLO-centric. Six panels total:

1. **Availability SLI (1h)** — stat with thresholds (red below 98.5%, green above 99%)
2. **Latency p99 (5m)** — stat with thresholds against the 250ms SLO target
3. **Error Budget Remaining (30d)** — gauge from 0 to 1
4. **Request Rate** — current req/s for context
5. **Availability SLI over time** — timeseries with 5m and 1h smoothing, with the 0.99 SLO line drawn
6. **Latency percentiles over time** — p50 and p99 with the 250ms SLO line drawn
7. **Request rate by HTTP status class** — stacked area, 2xx green / 4xx orange / 5xx red — instantly shows when the 5xx band starts growing

This is the dashboard you'd put on a wall-mounted monitor in an SRE bullpen.

## Dependencies

This dashboard queries the recording rules defined in `../alerts/slo-availability.yaml` and `../alerts/slo-latency.yaml`. You must apply those PrometheusRule manifests first:

```bash
kubectl apply -f alerts/ -n monitoring
```

Without them, the SLI panels will show "No data."

## Importing

### Option A — via Grafana UI

1. Open Grafana → left sidebar → **Dashboards** → **New** → **Import**
2. Click **Upload JSON file** → select `pulsehealth-slo-overview.json`
3. Select the Prometheus data source (named "Prometheus" or "kube-prometheus-stack-prometheus")
4. Click **Import**

### Option B — via Kubernetes ConfigMap (GitOps-friendly)

For real production use, you'd want this dashboard provisioned automatically when the cluster comes up, not imported by hand. The kube-prometheus-stack Grafana subchart supports sidecar-based dashboard provisioning via ConfigMaps:

```bash
kubectl create configmap pulsehealth-slo-overview \
  --from-file=dashboards/pulsehealth-slo-overview.json \
  -n monitoring \
  --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 -o yaml \
  | kubectl apply -f -
```

The `grafana_dashboard=1` label is what the Grafana sidecar watches. Once applied, the dashboard appears in Grafana automatically — no UI clicks. This is the pattern production deployments use.

## Editing the dashboard

If you tweak the dashboard in Grafana UI and want to update this JSON:

1. Open the dashboard in Grafana
2. Click the share icon (top-right) → **Export** tab
3. Toggle **Export for sharing externally** → **Save to file**
4. Replace the file in this directory with the downloaded JSON
5. Commit

When you do, scrub any environment-specific bits (data source UIDs, anything tied to your specific Grafana org).

## Why not more dashboards

Custom Grafana JSON is a maintenance liability — every Grafana major-version upgrade can break panel options. A single focused SLO dashboard is more valuable than five generic ones that compete with the pre-built kube-prometheus-stack set.

For everything else (cluster CPU/memory, per-namespace workloads, persistent volumes, node-exporter, etc.) the pre-built dashboards already do the job. Those are visible in `docs/screenshots/` as captured proof.

## v2 candidates (NOT in this repo)

If this were a production deployment:

- **Per-microservice SLO dashboard** for each of the 12 Online Boutique services
- **Customer journey latency** dashboard (homepage → product → cart → checkout)
- **gRPC inter-service latency** (would need OpenTelemetry instrumentation)
- **Cost dashboard** combining Prometheus metrics with AWS Cost Explorer data

These are scoped out of this case study but documented in `../CASE_STUDY.md` as future work.
