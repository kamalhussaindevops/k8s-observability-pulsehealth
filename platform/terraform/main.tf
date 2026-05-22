data "aws_availability_zones" "available" {
  state = "available"
}

# VPC with public subnets only.
# Public subnets avoid the NAT gateway cost (~$32/month).
# Production would use private + NAT.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs            = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets = ["10.0.1.0/24", "10.0.2.0/24"]

  enable_nat_gateway      = false
  map_public_ip_on_launch = true

  # Required for EKS to discover subnets for LoadBalancer services
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
}

# EKS cluster + managed node group
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = true

  # Grants the IAM identity running terraform admin access to the cluster
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = {}
    eks-pod-identity-agent = {}
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  eks_managed_node_groups = {
    workers = {
      instance_types = ["m7i-flex.large"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2

      # Label matches existing kube-prometheus-stack values.yaml nodeSelector
      labels = {
        workload-tier = "platform"
      }
    }
  }
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Run this to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
