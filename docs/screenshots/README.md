# PulseHealth EKS Observability — Screenshot Index

## Infrastructure (live AWS proof)
- `01-online-boutique-homepage.png` — Live Online Boutique app served via AWS Network Load Balancer
- `03-aws-console-eks-cluster.png` — AWS Console showing pulsehealth EKS cluster (Active)
- `03b-aws-console-addons.png` — EKS addons: vpc-cni, coredns, kube-proxy, eks-pod-identity-agent, aws-ebs-csi-driver
- `04-aws-console-nlb.png` — AWS Network Load Balancer (internet-facing, multi-AZ)
- `04b-aws-console-nlb-detail.png` — NLB detail view with listeners

## Observability (Grafana dashboards live on EKS)
- `05-grafana-nginx-ingress-dashboard.png` — NGINX Ingress metrics: 96.7% success rate, sub-50ms p99 latency
- `06-grafana-cluster-resources.png` — Cluster CPU/memory utilization by namespace
- `07-grafana-persistent-volumes.png` — EBS-backed PVCs (gp3, encrypted via CSI driver + IRSA)
- `07-prometheus-targets-nginx-up.png` — Prometheus Targets page: ingress-nginx ServiceMonitor UP
- `07b-prometheus-query-nginx-requests.png` — Live PromQL on nginx_ingress_controller_requests
- `08-grafana-node-exporter.png` — Per-node metrics for both m7i-flex.large workers
- `09-grafana-online-boutique.png` — Per-microservice observability for 12 Online Boutique services
