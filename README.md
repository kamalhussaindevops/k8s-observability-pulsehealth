# PulseHealth — Kubernetes Observability on AWS EKS

[![Terraform](https://img.shields.io/badge/Terraform-AWS-7B42BC?logo=terraform)](https://www.terraform.io)
[![EKS](https://img.shields.io/badge/Kubernetes-EKS_1.30-326CE5?logo=kubernetes)](https://aws.amazon.com/eks/)
[![Helm](https://img.shields.io/badge/Helm-Charts-0F1689?logo=helm)](https://helm.sh)
[![Prometheus](https://img.shields.io/badge/Prometheus-kube--prometheus--stack-E6522C?logo=prometheus)](https://prometheus.io)

Production-grade observability stack deployed on AWS EKS. Terraform for infrastructure, Helm for workloads, kube-prometheus-stack for metrics, ingress-nginx behind an AWS Network Load Balancer for public traffic. Tested end-to-end with live SLI metrics (96.7% success rate, sub-50ms p99 latency under load).

> **Built and torn down in ~19 hours of cluster runtime, for ~$6.50 of AWS spend.** Captured 11 proof screenshots; documented 7 production-relevant lessons in `LESSONS.md`.

## What's inside

- **`platform/terraform/`** — Terraform module for VPC + EKS + IRSA + EBS CSI driver. Single `terraform apply` brings up everything from scratch.
- **`platform/kube-prometheus-stack/`** — Helm values for Prometheus/Alertmanager/Grafana, with environment-specific overlays for kind (dev) vs EKS (cloud).
- **`platform/ingress-nginx/`** — Helm values for the ingress controller, with separate overlays for kind (DaemonSet + hostPort) and EKS (Deployment + NLB).
- **`platform/storage/`** — gp3 encrypted StorageClass using the AWS EBS CSI driver.
- **`apps/online-boutique/`** — Google Cloud Online Boutique microservices demo (12 services) with EKS-specific Ingress.
- **`apps/grafana-public-access/`** — Grafana exposed through the same NLB via nip.io wildcard DNS.
- **`docs/screenshots/`** — Live proof captures (AWS Console, Grafana dashboards, Prometheus targets).
- **`LESSONS.md`** — Seven real lessons learned. Worth more than the dashboards.
- **`DESTROY-RUNBOOK.md`** — Production teardown procedure (handles orphan Kubernetes-owned cloud resources properly).
- **`CASE_STUDY.md`** — Full project writeup with architecture diagram and cost analysis.

## Quick tour

For the full story:
1. **`CASE_STUDY.md`** — start here for the project overview
2. **`docs/screenshots/README.md`** — proof artifacts index
3. **`LESSONS.md`** — what I'd do differently next time
4. **`DESTROY-RUNBOOK.md`** — how to take it down cleanly

For the code:
- `platform/terraform/main.tf` — all AWS infrastructure
- `platform/*/values-eks.yaml` — EKS Helm overlays
- `apps/online-boutique/ingress-eks.yaml` — ingress routing

## Quick deploy

```bash
# 1. Infrastructure (~15 min)
cd platform/terraform
terraform init
terraform apply

# 2. kubeconfig
aws eks update-kubeconfig --region ap-south-1 --name pulsehealth

# 3. Default storage class (gp3, encrypted, via CSI)
kubectl apply -f platform/storage/gp3-storageclass.yaml
kubectl patch storageclass gp2 -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'

# 4. Observability stack (~5 min)
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --values platform/kube-prometheus-stack/values-eks.yaml --wait

# 5. Ingress controller (~3 min for NLB provisioning)
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --values platform/ingress-nginx/values-eks.yaml --wait

# 6. Demo app
kubectl create namespace online-boutique
kubectl apply -f apps/online-boutique/kubernetes-manifests.yaml -n online-boutique
kubectl apply -f apps/online-boutique/ingress-eks.yaml

# 7. Grafana public access (replace NLB_IP)
NLB_IP=$(dig +short $(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}') | head -1)
sed "s|grafana\.[^.]*\.[^.]*\.[^.]*\.[^.]*\.nip\.io|grafana.${NLB_IP}.nip.io|" \
  apps/grafana-public-access/ingress-eks.yaml | kubectl apply -f -

# Access:
echo "Online Boutique: http://$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')/"
echo "Grafana:         http://grafana.${NLB_IP}.nip.io/"
```

## Cleanup

**Do not skip the LoadBalancer Service and PVC deletions before `terraform destroy`.** See `DESTROY-RUNBOOK.md` for the full procedure.

```bash
kubectl delete svc -A --field-selector spec.type=LoadBalancer
kubectl delete pvc --all -A
sleep 180
cd platform/terraform
terraform destroy
```

## Stack reference

| Layer | Tool | Purpose |
| ----- | ---- | ------- |
| Infrastructure | Terraform (community modules) | VPC, EKS, IRSA, EBS CSI addon |
| Cluster | AWS EKS 1.30, 2× m7i-flex.large | Managed Kubernetes control plane + workers |
| Storage | EBS gp3 (encrypted, CSI-provisioned) | Persistent volumes for Prometheus/Alertmanager/Grafana |
| Networking | AWS NLB → ingress-nginx → services | Public ingress, multi-AZ, host-based routing |
| DNS (for demo) | nip.io wildcard | No real domain required |
| Observability | kube-prometheus-stack (Helm) | Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics |
| Demo workload | Online Boutique (12 microservices) | Polyglot, gRPC-heavy, real traffic generator |

## License

See `LICENSE`.
