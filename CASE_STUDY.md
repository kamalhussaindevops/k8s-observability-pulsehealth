# PulseHealth — Kubernetes Observability Case Study

## Summary

Deployed a production-grade Kubernetes observability platform on AWS EKS using Terraform for infrastructure, Helm for workload management, and the kube-prometheus-stack for metrics, with ingress-nginx fronted by an AWS Network Load Balancer for public traffic. Captured live SLI metrics (96.7% success rate, sub-50ms p99 latency) under real load. Built in two phases — local kind cluster for development, EKS for cloud deployment — using environment-specific Helm value overlays for clean separation.

This README covers the cloud deployment. The local kind work and the SLO/PromQL design lives under `dashboards/`, `alerts/`, and `kind/`.

---

## Architecture

```
                    ┌─────────────────────────────────────────────────┐
                    │                AWS ap-south-1                    │
                    │                                                  │
   Internet         │  ┌──────────────────────────────────────────┐   │
   ────────────────▶│  │      AWS Network Load Balancer           │   │
                    │  │      (multi-AZ, internet-facing)         │   │
                    │  └──────────────────┬───────────────────────┘   │
                    │                     │                            │
                    │  ┌──────────────────▼───────────────────────┐   │
                    │  │      EKS Cluster (1.30, 2× m7i-flex.large)│   │
                    │  │                                            │   │
                    │  │   ┌────────────────────────────────────┐  │   │
                    │  │   │  ingress-nginx (2 replicas, NLB-   │  │   │
                    │  │   │  fronted; routes to backends)      │  │   │
                    │  │   └──┬──────────────────────┬──────────┘  │   │
                    │  │      │                      │              │   │
                    │  │  ┌───▼──────┐         ┌─────▼──────┐      │   │
                    │  │  │ Online   │         │  Grafana   │      │   │
                    │  │  │ Boutique │         │  (via nip.io│      │   │
                    │  │  │ (12 svcs)│         │   subdomain)│      │   │
                    │  │  └──────────┘         └─────┬──────┘      │   │
                    │  │                              │              │   │
                    │  │  ┌──────────────┐  ┌────────▼─────────┐   │   │
                    │  │  │   Prometheus │  │   Alertmanager   │   │   │
                    │  │  │   (10Gi PVC) │  │   (2Gi PVC)       │   │   │
                    │  │  └──────────────┘  └──────────────────┘   │   │
                    │  │         All PVCs: gp3 EBS, encrypted       │   │
                    │  │              via EBS CSI + IRSA            │   │
                    │  └────────────────────────────────────────────┘   │
                    └─────────────────────────────────────────────────┘
```

### Key architecture decisions

| Decision | Reason |
| -------- | ------ |
| Public subnets only (no NAT) | Saves ~$32/month NAT Gateway cost; nodes still reach internet directly via IGW |
| 2× m7i-flex.large workers | AWS Free Plan-eligible (post-July-2025) for accounts that qualify; ~4 vCPU / 16 GB total |
| ingress-nginx + NLB (no AWS LB Controller) | Simpler setup; in-tree cloud-controller-manager creates the NLB from the Service annotations |
| gp3 with CSI driver via IRSA | Modern storage path; gp3 is ~20% cheaper than gp2 with same performance; IRSA scopes EBS permissions to the controller's ServiceAccount only |
| `nip.io` for Grafana hostname | Wildcard DNS service avoids real-domain registration for the demo |
| Environment-specific Helm value overlays (`values.yaml` for kind, `values-eks.yaml` for EKS) | Single source of truth for the shared chart; environment-specific overrides only contain what differs |

---

## Stack

**Infrastructure (Terraform)**
- `terraform-aws-modules/vpc/aws` (VPC, 2 public subnets across 2 AZs, IGW, route tables)
- `terraform-aws-modules/eks/aws` (cluster, managed node group, addons: vpc-cni, coredns, kube-proxy, eks-pod-identity-agent, aws-ebs-csi-driver)
- `terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks` (IRSA role for EBS CSI driver)

**Workloads (Helm)**
- `prometheus-community/kube-prometheus-stack` (Prometheus + Alertmanager + Grafana + kube-state-metrics + node-exporter)
- `ingress-nginx/ingress-nginx` (ingress controller with NLB service type)

**Application (kubectl)**
- Google Cloud Online Boutique microservices demo (12 services, polyglot, gRPC-heavy)

**Storage**
- EBS gp3 via the AWS EBS CSI driver (encrypted at rest)
- 3 PersistentVolumeClaims (Prometheus 10Gi, Alertmanager 2Gi, Grafana 2Gi)

**Access**
- Online Boutique: `http://<NLB-hostname>/` (root path)
- Grafana: `http://grafana.<NLB-IP>.nip.io/` (host-based routing via nip.io wildcard DNS)
- Both fronted by ingress-nginx, both fronted by the same NLB

---

## Repository layout

```
.
├── apps/
│   ├── online-boutique/
│   │   ├── kubernetes-manifests.yaml         # 12 services from googlecloudplatform/microservices-demo
│   │   ├── ingress.yaml                      # kind-specific ingress
│   │   └── ingress-eks.yaml                  # EKS NLB ingress (no host restriction)
│   └── grafana-public-access/
│       └── ingress-eks.yaml                  # Grafana via nip.io subdomain
├── platform/
│   ├── terraform/                            # IaC for VPC + EKS + IRSA
│   │   ├── main.tf                            # All AWS infra
│   │   ├── variables.tf
│   │   └── versions.tf
│   ├── ingress-nginx/
│   │   ├── values.yaml                       # kind overlay (DaemonSet, hostPort, webhooks off)
│   │   └── values-eks.yaml                   # EKS overlay (Deployment, NLB, webhooks on)
│   ├── kube-prometheus-stack/
│   │   ├── values.yaml                       # kind overlay
│   │   └── values-eks.yaml                   # EKS overlay (gp3 storage, tuned resource limits)
│   └── storage/
│       └── gp3-storageclass.yaml             # CSI-backed default StorageClass
├── kind/                                     # Phase 1 local cluster bootstrap
├── alerts/                                   # Prometheus alerting rules
├── dashboards/                               # Custom Grafana dashboards
├── docs/
│   └── screenshots/                          # Captured proof artifacts (11 PNG + index)
├── scripts/                                  # Helper scripts
├── LESSONS.md                                # 7 lessons learned the hard way
├── DESTROY-RUNBOOK.md                        # Production teardown procedure
└── README.md
```

---

## Deployment phases

### Phase 1 — Local development (kind cluster)

Built the full observability stack on a single-node kind cluster running on a 10 GB / 2 vCPU VM. Validated:
- kube-prometheus-stack installation and CRDs (`ServiceMonitor`, `PodMonitor`, `PrometheusRule`)
- ingress-nginx integration with Prometheus via `ServiceMonitor`
- PromQL queries on `nginx_ingress_controller_requests` and related metrics
- Helm chart debugging and value overlays
- SLO design and PromQL recording rules

Used here as the development substrate; the EKS deployment reuses the same Helm chart with overlay values.

### Phase 2 — Production deployment (EKS)

Translated the validated Phase 1 stack to AWS EKS:

1. **Infrastructure**: `terraform apply` provisions VPC, EKS, node group, OIDC provider, IRSA role for EBS CSI.
2. **StorageClass**: Apply `platform/storage/gp3-storageclass.yaml` to set gp3 as cluster default.
3. **Observability stack**: `helm install kube-prometheus-stack -f platform/kube-prometheus-stack/values-eks.yaml`
4. **Ingress controller**: `helm install ingress-nginx -f platform/ingress-nginx/values-eks.yaml` — AWS provisions an NLB automatically.
5. **Application**: `kubectl apply -f apps/online-boutique/kubernetes-manifests.yaml` then `apps/online-boutique/ingress-eks.yaml`.
6. **Grafana public access**: `kubectl apply -f apps/grafana-public-access/ingress-eks.yaml`.

Total deploy time end-to-end: ~30 minutes (Terraform: ~15 min for control plane + nodes, Helm installs: ~10 min combined, including wait-for-NLB).

---

## Proof of operation

See `docs/screenshots/README.md` for the captured artifacts index. Highlights:

- **`05-grafana-nginx-ingress-dashboard.png`** — Live NGINX Ingress dashboard: 96.7% success rate, p50=3ms / p90=9ms / p99=44ms latency, two ingresses tracked (online-boutique and grafana itself).
- **`07-grafana-persistent-volumes.png`** — All 3 PVCs Bound to gp3 with EBS volume IDs visible.
- **`07-prometheus-targets-nginx-up.png`** — Prometheus Targets page showing the ingress-nginx `ServiceMonitor` discovered and UP.
- **`03-aws-console-eks-cluster.png`** + **`03b-aws-console-addons.png`** — AWS Console proof that the cluster is real and includes all expected addons.

---

## Cost analysis

Total spend across ~19 hours of cluster lifetime:

| Item | Hours | Rate | Cost |
| ---- | ----- | ---- | ---- |
| EKS control plane | 19 | $0.10/hr | $1.90 |
| 2× m7i-flex.large workers | 19 | $0.18/hr combined | $3.42 |
| NLB (ingress) + orphan CLB | ~24 | ~$0.025/hr | $0.80 |
| EBS gp3 storage (14 GB total) | ~24 | ~$0.001/hr | $0.20 |
| Data transfer | ~ | — | ~$0.10 |
| **Total** | | | **~$6.50** |

For a full production-architecture EKS deployment with persistent storage, public load balancing, multi-AZ networking, complete observability, and a 12-microservice demo app, ~$6.50 is an objectively excellent ROI for the artifact set produced.

---

## What this demonstrates

For prospective clients evaluating this work, the relevant signal:

- **Terraform-native infrastructure** (not click-ops) using community modules and IRSA for least-privilege cloud permissions
- **Helm with environment overlays** — the pattern most production teams use, not a single-environment config
- **Observability stack deployed and proven via real metrics**, not just installed
- **End-to-end public traffic flow** through AWS NLB → ingress-nginx → application pod, with a documented hostname (no port-forward dependency)
- **Live diagnosis and remediation under fire** — Grafana OOM-loop diagnosed via exit code, fixed via Helm upgrade with `--reuse-values`, captured as `LESSONS.md` entry
- **Proper teardown discipline** — including the production-relevant runbook for orphan Kubernetes-owned cloud resources

The project intentionally limits scope: no Loki/Tempo (compute envelope was tight), no AWS Load Balancer Controller (NLB via in-tree integration was sufficient), no real domain (nip.io substituted). Each omission is documented as a v2 expansion path rather than a gap.

---

## Lessons

See `LESSONS.md` for seven real lessons earned during this project. The teardown lesson alone (Kubernetes-owned cloud resource orphans) is worth more than the entire build phase in terms of actual production relevance.

---

## License

See `LICENSE`.
