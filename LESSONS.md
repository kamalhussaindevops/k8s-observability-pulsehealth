# Lessons Learned

Real lessons from real failures encountered while building and tearing down this stack. Each one cost time and (in some cases) money to learn. Documenting them so future-me — and anyone reading this repo — doesn't repeat them.

---

## 1. Terraform destroy is unreliable for VPCs containing Kubernetes-owned resources

**Symptom:** `terraform destroy` hangs for 20+ minutes on subnets/IGW/VPC and then errors out:

```
Error: deleting EC2 Internet Gateway: DependencyViolation: Network has some
mapped public address(es). Please unmap those public address(es) before
detaching the gateway.

Error: deleting EC2 Subnet: DependencyViolation: The subnet has dependencies
and cannot be deleted.
```

**Root cause:** When a Kubernetes `Service` of type `LoadBalancer` is created, the cluster's cloud-controller-manager provisions an AWS load balancer (NLB or CLB depending on annotations) and attaches Elastic Network Interfaces (ENIs) to the VPC's subnets. These cloud resources are owned by Kubernetes, not by Terraform's state. When `terraform destroy` kills the EKS cluster *before* the LoadBalancer Service is explicitly deleted, the cloud-controller-manager never runs the cleanup, so the LB + ENIs are stranded. Terraform then fails to delete the subnets because they still hold those ENIs, and the IGW can't detach because the LB's public IPs are still mapped.

**Correct teardown sequence:**

```bash
# 1. Delete LoadBalancer Services first (this triggers cloud-controller-manager cleanup)
kubectl delete svc -A --field-selector spec.type=LoadBalancer

# 2. Delete PVCs (triggers EBS CSI driver cleanup of EBS volumes)
kubectl delete pvc --all -A

# 3. Wait 2-3 minutes for AWS-side cleanup to complete
sleep 180

# 4. NOW run terraform destroy
terraform destroy
```

See `DESTROY-RUNBOOK.md` for the full procedure and manual orphan-cleanup recipes.

---

## 2. `kubectl port-forward` is fragile under sustained UI traffic

**Symptom:** Port-forward to a Grafana pod dies repeatedly during dashboard use:

```
error forwarding port 3000: failed to connect to localhost:3000 inside namespace
"...": dial tcp4 127.0.0.1:3000: connect: connection refused
error: lost connection to pod
```

**Root cause:** Modern browsers open many parallel HTTP/2 connections per page (prefetch, websockets, image streams, dashboard auto-refresh polling). `kubectl port-forward` multiplexes them through a single SPDY stream to the pod, and the stream gets overwhelmed. The target process inside the pod may also crash under burst load (e.g., Grafana hitting an OOM limit and getting SIGKILL'd mid-connection), which surfaces as "connection refused inside namespace."

**Fix used in this project:** Stop fighting port-forward; expose the service through the existing production-grade NLB + ingress-nginx, with `nip.io` for a wildcard DNS hostname so no real domain was required. See `apps/grafana-public-access/ingress-eks.yaml`. Rock-solid stability, no port-forward needed.

**Production takeaway:** `kubectl port-forward` is a debugging tool, not a production access pattern. If a workload needs sustained UI access, give it an Ingress.

---

## 3. Trust-but-verify Helm resource limits

**Symptom:** Grafana pod crashes repeatedly, restart count climbs (3, 5, 7, 8...) over several hours. Dashboards work briefly, then 503. `kubectl describe pod` reveals:

```
Last State:    Terminated
  Reason:      OOMKilled
  Exit Code:   137
```

**Root cause:** `values-eks.yaml` initially set Grafana's memory limit to 256Mi, which seemed reasonable on paper. Under real dashboard query load (multiple panels, time-range expansions, the kube-prometheus-stack provider initializing) memory consistently spiked past that limit. The Linux kernel sent SIGKILL (exit code 137), kubelet restarted the container, and the loop continued.

**Diagnostic:** Exit code 137 = SIGKILL from the kernel, almost always an OOM kill. Always check `Last State` and `Reason` in `kubectl describe pod` when investigating restart loops.

**Fix:** Bumped to 768Mi via Helm upgrade with `--reuse-values`. Stable immediately, no further restarts.

```yaml
grafana:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 1
      memory: 768Mi   # was 256Mi — too aggressive
```

**Production takeaway:** Resource limits taken from "looks reasonable" guesses are a leading cause of production instability. Either size with real load testing data or run un-limited briefly to observe actual usage, then set limits to ~2x peak.

---

## 4. `sed -i` succeeds silently on no matches

**Symptom:** Ran `sed -i 's/t3.medium/m7i-flex.large/' main.tf` expecting an instance-type swap. Got no output (success). Ran `terraform plan`, plan completed. Ran `terraform apply` — node group failed with `InvalidParameterCombination: The specified instance type is not eligible for Free Tier`. **The sed never matched.**

**Root cause:** `sed -i` exits with code 0 whether it replaced anything or not. The actual file still said `t3.medium`. We assumed "exit 0 = command did what I wanted" — but exit codes only tell you the command *ran*, not that it had any effect.

**Fix discipline:** Always verify after sed/yq/jq with grep:

```bash
sed -i 's/t3.medium/m7i-flex.large/' main.tf
grep -n instance_types main.tf   # MUST show the new value before proceeding
```

**Production takeaway:** Silent success is the most dangerous failure mode in shell tooling. Build a habit of "verify after every in-place edit," not "trust the exit code."

---

## 5. Pasting multi-line bash into the shell pollutes the working directory

**Symptom:** After hours of copy-pasting heredocs and command blocks into the terminal, `ls` revealed files with names like:

```
' {'
'= {'
'_availability_zones" "available" {'
'(kube-system:ebs-csi-controller-sa) assume this'
'existing kube-prometheus-stack values.yaml nodeSelector'
'ubnets only.'
```

**Root cause:** Multi-line shell pastes containing braces, quotes, comments, or partial commands get mid-parsed by the shell. Lines that start with `{`, `>`, or look like assignments get interpreted as commands or redirects, sometimes creating files with weird names.

**Fix:** Cleaned them up with `find -delete`. But the real fix is prevention:

```bash
# DON'T paste multi-line content directly into the shell
# DO paste into an editor first
nano values-eks.yaml   # paste, save, exit
```

Or use heredocs with a sentinel that can't collide with your content (`'EOF_PULSEHEALTH'`, not just `EOF`).

**Production takeaway:** The shell is not a text editor. Treat paste-into-terminal as an attack surface for accidental file creation. Use `nano`, `vim`, `cat > file <<EOF` only with unique sentinels.

---

## 6. `aws elbv2 describe-load-balancers` only shows ALBs and NLBs

**Symptom:** After multiple `terraform destroy` failures, `aws elbv2 describe-load-balancers` returned empty. But the VPC still had ENIs labeled `ELB a65c80642188f4b34a3eb52408972d00` blocking subnet deletion.

**Root cause:** AWS has two ELB APIs:
- `elbv2` (v2) lists **Application Load Balancers** and **Network Load Balancers**
- `elb` (v1) lists **Classic Load Balancers**

A `Service` of type `LoadBalancer` *without* AWS-specific annotations creates a **Classic Load Balancer** by default. The Online Boutique manifests include a `frontend-external` service of type LoadBalancer with no annotations — it silently spawned a CLB that we never used directly (we routed through ingress-nginx) but which sat there using ENIs in the VPC.

**Audit-for-orphans command set:**

```bash
# Both APIs must be checked
aws elbv2 describe-load-balancers --region <region>
aws elb describe-load-balancers --region <region>

# Plus low-level ENI check that catches everything
aws ec2 describe-network-interfaces --region <region> \
  --filters "Name=vpc-id,Values=<vpc-id>"
```

**Production takeaway:** Before destroying a VPC, always check BOTH ELB APIs, plus enumerate ENIs in the VPC. Either-or queries leave Classic LBs hidden.

---

## 7. AWS Free Plan post-July-2025 strictly restricts EC2 instance types

**Symptom:** EKS node group creation failed:

```
InvalidParameterCombination: The specified instance type is not eligible for
Free Tier. For a list of Free Tier instance types, run 'describe-instance-types'
with the filter 'free-tier-eligible=true'.
```

We were trying `t3.medium` — a perfectly normal small instance.

**Root cause:** AWS changed the Free Tier model on July 15, 2025. Accounts created on or after that date only get Free Tier eligibility for a specific, narrow allowlist:

- `t3.micro`, `t3.small`
- `t4g.micro`, `t4g.small`
- `c7i-flex.large`, `m7i-flex.large`

Nothing else qualifies. `t3.medium` is *not* on the list — even though it's a small, common instance.

**Confirm your account's actual allowed list:**

```bash
aws ec2 describe-instance-types --region <region> \
  --filters Name=free-tier-eligible,Values=true \
  --query "InstanceTypes[*].[InstanceType]" --output text | sort
```

**Project decision:** Used `m7i-flex.large` (2 vCPU, 8 GB RAM per node, 2 nodes = 4 vCPU / 16 GB cluster total). Plenty for kube-prometheus-stack + Online Boutique + ingress-nginx on a single test cluster.

**Production takeaway:** Always validate the AWS Free Plan eligibility for your specific account before assuming instance types are available. The Free Tier rules change, and old tutorials may reference instance types that no longer qualify.

---

## Meta-lesson

The deployment phase took ~3 hours of effective work. The teardown phase took another ~2 hours, because orphan resources hid in places we hadn't audited.

**Build the destroy procedure as carefully as you build the create procedure.** Both go in version control. Both get tested. `terraform apply` and `terraform destroy` aren't symmetric: apply assumes a clean slate, destroy assumes a cooperative environment. The latter is harder.
