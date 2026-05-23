# Operational Scripts

Real scripts used during this project's lifecycle. Each is parameterized, idempotent where possible, and documents its own usage at the top.

| Script | Purpose | When you'd run it |
| ------ | ------- | ----------------- |
| `deploy.sh` | End-to-end deployment: Terraform → kubeconfig → StorageClass → kube-prometheus-stack → ingress-nginx → Online Boutique → Ingress | Fresh deploy or after `destroy-safe.sh` |
| `destroy-safe.sh` | Production-correct teardown: deletes LoadBalancer Services + PVCs first, audits orphans, then `terraform destroy` | When you're done and need to stop the cost meter |
| `gen-traffic.sh` | Generates realistic traffic (homepage, products, cart) against the public NLB | Before screenshotting dashboards; during load testing |
| `audit-aws-orphans.sh` | Audits AWS for stranded resources (LBs, ENIs, EBS volumes, EIPs) — both `elbv2` AND `elb` APIs | After destroy to verify cleanup; or before destroy to diagnose what's blocking it |
| `verify-deploy.sh` | Health-check the full stack (nodes, pods, PVCs, NLB, Prometheus targets); CI-friendly (exits non-zero on failure) | After deploy, after a long break, or before client demos |

## Why these scripts exist

This project taught us that **terraform alone is not enough** for the EKS lifecycle. Kubernetes-owned cloud resources (LBs from `Service type: LoadBalancer`, EBS volumes from PVCs) require Kubernetes-side cleanup before infrastructure teardown. `destroy-safe.sh` encodes that sequence. `audit-aws-orphans.sh` finds what slipped through.

See `../LESSONS.md` and `../DESTROY-RUNBOOK.md` for the engineering reasoning behind each script.

## Running

All scripts assume:
- AWS CLI v2 configured (`aws sts get-caller-identity` works)
- `kubectl` context pointed at the right cluster
- The repo cloned with relative paths intact

```bash
# Make executable on first checkout
chmod +x scripts/*.sh

# Then run from anywhere:
./scripts/deploy.sh
./scripts/verify-deploy.sh
./scripts/gen-traffic.sh -d 300       # 5 minutes
./scripts/audit-aws-orphans.sh
./scripts/destroy-safe.sh
```

## Environment overrides

All scripts respect:
- `REGION` (default: `ap-south-1`)
- `CLUSTER_NAME` (default: `pulsehealth`)
- `REPO_ROOT` (default: derived from script location)

Example:

```bash
REGION=us-east-1 CLUSTER_NAME=pulsehealth-prod ./deploy.sh
```
