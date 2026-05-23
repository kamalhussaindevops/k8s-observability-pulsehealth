# EKS Destroy Runbook

A production teardown procedure for any EKS cluster managed by this repository's Terraform. Written after learning the hard way that `terraform destroy` alone is not enough.

> **Why this exists:** Kubernetes creates cloud resources (LoadBalancers, ENIs, EBS volumes) that Terraform doesn't know about. Killing the EKS cluster before deleting those resources strands them in the VPC, then Terraform can't delete the VPC because the orphans are still there. Result: hours wasted in failed destroy loops.

## TL;DR — destroy procedure

```bash
# 1. Pre-destroy: delete Kubernetes-owned cloud resources FIRST
kubectl delete svc -A --field-selector spec.type=LoadBalancer
kubectl delete pvc --all -A

# 2. Wait for AWS-side cleanup (cloud-controller-manager takes 1-3 min)
sleep 180

# 3. Verify VPC is clean of Kubernetes orphans (see "Audit" section below)

# 4. NOW run terraform destroy
cd platform/terraform
terraform destroy

# 5. Verify nothing remains (see "Final verification" section)
```

If step 4 fails with `DependencyViolation`, see the "Manual cleanup" section.

---

## Step-by-step

### Step 1 — Inventory what's running

Know what you have before tearing down. From the working directory:

```bash
kubectl get svc -A --field-selector spec.type=LoadBalancer
# Expect: lists all Services backed by AWS LBs (NLB or CLB)

kubectl get pvc -A
# Expect: lists all PersistentVolumeClaims and the bound EBS volumes

kubectl get ingress -A
# Expect: lists Ingress resources; these don't directly create AWS resources,
# but they reference the ingress-nginx controller Service which does
```

Confirm each item is something you're prepared to delete. If anything is unexpected, investigate before proceeding.

### Step 2 — Delete LoadBalancer Services

```bash
# Across all namespaces
kubectl delete svc -A --field-selector spec.type=LoadBalancer
```

This triggers the cloud-controller-manager to delete the underlying AWS load balancers (NLB and/or CLB) and free up their ENIs. **This is the most important step.** Skipping it strands LBs in the VPC.

Confirm cleanup has started:

```bash
# Watch the LBs disappear (should take 1-3 minutes per LB)
watch -n 5 'aws elbv2 describe-load-balancers --region <region> --query "LoadBalancers[].LoadBalancerName" --output table && aws elb describe-load-balancers --region <region> --query "LoadBalancerDescriptions[].LoadBalancerName" --output table'
```

(Watch both `elbv2` and `elb` — see "Why both ELB APIs" below.)

### Step 3 — Delete PersistentVolumeClaims

```bash
kubectl delete pvc --all -A
```

This triggers the EBS CSI driver to delete the underlying EBS volumes. With `reclaimPolicy: Delete` on the StorageClass (the default for gp3 in this project), the EBS volumes get deleted automatically. With `reclaimPolicy: Retain`, you'd need to delete them manually post-destroy.

### Step 4 — Wait for AWS-side cleanup

```bash
sleep 180
```

3 minutes. The cloud-controller-manager and CSI driver run asynchronously; AWS API calls are eventually consistent.

### Step 5 — Audit the VPC for orphans

```bash
VPC=$(terraform output -raw vpc_id 2>/dev/null || \
      aws ec2 describe-vpcs --region <region> \
        --filters "Name=tag:Name,Values=<cluster-name>-vpc" \
        --query "Vpcs[0].VpcId" --output text)
echo "VPC: $VPC"

# These four queries together find every kind of resource that can block VPC deletion
aws elbv2 describe-load-balancers --region <region> \
  --query "LoadBalancers[?VpcId=='$VPC'].[LoadBalancerName,State.Code]" --output table

aws elb describe-load-balancers --region <region> \
  --query "LoadBalancerDescriptions[?VPCId=='$VPC'].[LoadBalancerName,State]" --output table

aws ec2 describe-network-interfaces --region <region> \
  --filters "Name=vpc-id,Values=$VPC" \
  --query "NetworkInterfaces[].[NetworkInterfaceId,Status,Description]" --output table

aws ec2 describe-security-groups --region <region> \
  --filters "Name=vpc-id,Values=$VPC" \
  --query "SecurityGroups[?GroupName!='default'].[GroupId,GroupName]" --output table
```

All four should return empty (or only show the default security group). If anything appears, see "Manual cleanup" below.

### Step 6 — Terraform destroy

```bash
cd platform/terraform
terraform destroy
```

Type `yes`. Should complete in 5-15 minutes for a single-cluster setup.

### Step 7 — Final verification

```bash
aws ec2 describe-instances --region <region> \
  --filters "Name=instance-state-name,Values=running,pending,stopping" --output table

aws elbv2 describe-load-balancers --region <region> --output table
aws elb describe-load-balancers --region <region> --output table

aws ec2 describe-volumes --region <region> \
  --filters "Name=status,Values=available" --output table

aws eks list-clusters --region <region> --output table

aws iam list-roles \
  --query "Roles[?starts_with(RoleName, '<cluster-name>')].[RoleName]" --output table
```

All six should be empty.

---

## Manual cleanup — when terraform destroy fails

If `terraform destroy` errors with `DependencyViolation: Network has some mapped public address(es)` or `subnet has dependencies`, something is still in the VPC. Diagnose with the audit queries in Step 5 above, then surgically remove the orphan.

### Orphan #1 — Stranded ELB (most common)

The orphan is usually a LoadBalancer the cloud-controller-manager didn't get to clean up.

**Diagnose:**

```bash
# Check BOTH ELB APIs — Classic and v2 live in different APIs
aws elbv2 describe-load-balancers --region <region> \
  --query "LoadBalancers[?VpcId=='$VPC'].LoadBalancerArn" --output text

aws elb describe-load-balancers --region <region> \
  --query "LoadBalancerDescriptions[?VPCId=='$VPC'].LoadBalancerName" --output text
```

**Delete an orphan NLB or ALB:**

```bash
aws elbv2 delete-load-balancer --region <region> --load-balancer-arn <arn>
```

**Delete an orphan Classic LB:**

```bash
aws elb delete-load-balancer --region <region> --load-balancer-name <name>
```

Wait 2 minutes after deletion for ENI cleanup.

### Orphan #2 — Stranded ENIs

Sometimes ENIs persist after their owning LB is deleted, especially if Lambda or other services attached to them.

**Find:**

```bash
aws ec2 describe-network-interfaces --region <region> \
  --filters "Name=vpc-id,Values=$VPC" \
  --query "NetworkInterfaces[].[NetworkInterfaceId,Status,Description]" --output table
```

**Force-detach (if attached) and delete:**

```bash
aws ec2 detach-network-interface --region <region> --attachment-id <attachment-id> --force
aws ec2 delete-network-interface --region <region> --network-interface-id <eni-id>
```

### Orphan #3 — Stranded security groups (k8s-elb-*)

When Kubernetes creates a Classic LB, it also creates a dedicated security group named `k8s-elb-<lb-id>`. The LB deletion sometimes leaves the SG behind.

**Find:**

```bash
aws ec2 describe-security-groups --region <region> \
  --filters "Name=vpc-id,Values=$VPC" \
  --query "SecurityGroups[?GroupName!='default'].[GroupId,GroupName]" --output table
```

**Delete:**

```bash
aws ec2 delete-security-group --region <region> --group-id <sg-id>
```

### Orphan #4 — EBS volumes from un-deleted PVCs

If you skipped `kubectl delete pvc` before destroy, the volumes are stranded.

**Find:**

```bash
aws ec2 describe-volumes --region <region> \
  --filters "Name=status,Values=available" \
  --query "Volumes[].[VolumeId,Size,Tags[?Key=='kubernetes.io/cluster/<cluster-name>'].Value]" \
  --output table
```

**Delete:**

```bash
aws ec2 delete-volume --region <region> --volume-id <vol-id>
```

### Last resort — delete the VPC directly

If terraform's state for the VPC is out of sync with reality and you've cleared all orphans:

```bash
aws ec2 delete-vpc --region <region> --vpc-id $VPC
```

Then nuke the terraform state for that VPC (so future terraform runs don't try to manage a VPC that no longer exists):

```bash
cd platform/terraform
terraform state rm module.vpc.aws_vpc.this[0]
# Or, if state is fully corrupted:
rm -f terraform.tfstate terraform.tfstate.backup
```

`main.tf` is your IaC source of truth; state is regenerable from the next `terraform init` + `terraform apply` if you ever redeploy.

---

## Why both ELB APIs (elbv2 vs elb)

AWS has two distinct ELB APIs:

| API | Type | Service | When it's used |
| --- | ---- | ------- | -------------- |
| `elb` (v1) | Classic Load Balancer (CLB) | `aws elb describe-load-balancers` | Default when a Kubernetes `Service` of type `LoadBalancer` has no AWS annotations |
| `elbv2` | Application LB, Network LB | `aws elbv2 describe-load-balancers` | When `aws-load-balancer-type: nlb` annotation is present, or when AWS Load Balancer Controller is installed |

A common production gotcha: the Online Boutique demo creates a `frontend-external` Service of type LoadBalancer with no AWS annotations. This silently spawns a CLB that you may never use directly but which holds ENIs in your VPC. Always check both APIs when auditing for orphans.

---

## When to use this runbook

- After demo/case study work (this project's primary use case)
- When migrating a cluster between regions or accounts
- After cost-spike investigations where you need to confirm all paid resources are gone
- When `terraform destroy` is failing and you need to know why

Apply the same audit logic in reverse for new deployments: before `terraform apply`, confirm the target region/VPC is empty so you don't collide with existing resources.
