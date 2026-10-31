module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.name
  cluster_version = var.kubernetes_version

  # API reachable from admin CIDRs (Terraform's Helm provider and kubectl use it).
  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.eks_public_access_cidrs
  cluster_endpoint_private_access      = true

  # Whoever runs terraform apply becomes cluster admin.
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_addons = {
    vpc-cni = {
      # Primary CNI. PAN CNI chains itself into its conflist (10-aws.conflist).
      most_recent    = true
      before_compute = true
    }
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    eks-pod-identity-agent = { most_recent = true }
  }

  eks_managed_node_groups = {
    default = {
      # Managed node groups only. PAN CNI is a DaemonSet, so Fargate pods are NOT protected.
      instance_types = [var.node_instance_type]
      ami_type       = "AL2023_x86_64_STANDARD"
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
    }
  }

  # Pods use the node security group (AWS VPC CNI default), so traffic the
  # firewall sends back/forwards to pods must be allowed here.
  node_security_group_additional_rules = {
    # Pod-to-pod on any port across nodes (module default only opens 1025-65535 node-to-node).
    ingress_self_all = {
      description = "Node to node all ports/protocols (pod-to-pod)"
      type        = "ingress"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      self        = true
    }
    # Demo apps: web (airs-demo) :80 and web2 (airs-demo-b) :81, pod-to-pod across nodes.
    # Already covered by ingress_self_all; kept explicit so the demo ports stay open
    # if the all-ports rule is ever tightened.
    ingress_self_demo_web = {
      description = "Node to node demo web ports 80-81 (web :80, web2 :81)"
      type        = "ingress"
      protocol    = "tcp"
      from_port   = 80
      to_port     = 81
      self        = true
    }
    ingress_from_airs_fw = {
      description              = "All traffic from the Prisma AIRS firewall data interface"
      type                     = "ingress"
      protocol                 = "-1"
      from_port                = 0
      to_port                  = 0
      source_security_group_id = aws_security_group.fw_data.id
    }
  }
}
