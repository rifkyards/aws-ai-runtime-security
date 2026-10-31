# Prisma AIRS Tag Collector ("Context Collector Agent" in SCM) in the SAME VPC.
#
# Adapted from the SCM-generated template (<alias>_AGENT_AWS_<REGION>_<id>):
#   tc_project     -> EC2 here (PA AIRS AMI, mgmt interface only, bootstrap user_data)
#   tc_iam_project -> IAM role the TC assumes to read the EKS cluster
#   tgw_project    -> NOT needed: the TC sits in this VPC's mgmt subnet and reaches
#                     the EKS private API endpoint over the VPC "local" route.
#                     (The generated TC VPC 10.20.0.0/16 would also overlap this VPC.)
#
# Added (not in the generated template, needed on EKS):
#   - EKS access entries (view) so the assumed role can read pods/namespaces/services
#   - cluster SG rule: HTTPS from the TC to the EKS API private endpoint
#
# Enable:  terraform apply -var enable_tag_collector=true
#          (tc_bootstrap_options comes from tag-collector.auto.tfvars)

variable "enable_tag_collector" {
  description = "Deploy the Prisma AIRS tag collector VM."
  type        = bool
  default     = false
}

variable "tc_bootstrap_options" {
  description = "Bootstrap options from the SCM-generated tc_project/terraform.tfvars (vmseries.tc.bootstrap_options), copied as-is."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "tc_instance_type" {
  description = "Tag collector instance type (SCM template: m5.xlarge)."
  type        = string
  default     = "m5.xlarge"
}

variable "tc_ami_id" {
  description = "Tag collector AMI. Empty = same AMI as the firewall (the SCM template uses the same one)."
  type        = string
  default     = ""
}

variable "tc_mgmt_ip" {
  description = "Static private IP of the tag collector mgmt interface. Empty = 11th host of mgmt_subnet_cidr."
  type        = string
  default     = ""
}

# Names kept identical to the SCM-generated template: SCM onboarding may expect them.
variable "tc_instance_role_name" {
  description = "IAM role of the TC VM. Use the name from your SCM template (tc_iam_project trusted_role_arn, <name_prefix>tc_vm01)."
  type        = string
  default     = "airs-tc_vm01"
}

variable "tc_cluster_role_name" {
  description = "IAM role the TC assumes to read clusters (SCM tc_iam_project role_name)."
  type        = string
  default     = "private_cluster_role"
}

variable "tc_cluster_policy_name" {
  description = "IAM policy attached to the cluster role (SCM tc_iam_project policy_name)."
  type        = string
  default     = "k8s-policy"
}

locals {
  tc         = var.enable_tag_collector ? 1 : 0
  tc_mgmt_ip = var.tc_mgmt_ip != "" ? var.tc_mgmt_ip : cidrhost(var.mgmt_subnet_cidr, 11)

  # Same keys and order as the SCM template (tc_project/main.tf).
  tc_bootstrap_keys = [
    "mgmt-interface-swap",
    "plugin-op-commands",
    "vm-auth-key",
    "dgname",
    "tplname",
    "dhcp-send-hostname",
    "dhcp-send-client-id",
    "dhcp-accept-server-hostname",
    "dhcp-accept-server-domain",
    "panorama-server",
    "authcodes",
    "vm-series-auto-registration-pin-id",
    "vm-series-auto-registration-pin-value",
    "tsg-id",
    "cdl-region",
    "ip-tag-svc-endpoint",
    "discovery-account-id",
    "cluster-account-ids",
  ]

  # Newline-separated like the SCM template: tplname contains ";" (otid:...;label:CtxColl),
  # so the ";" separator used for the firewall would break it.
  tc_user_data = join("\n", compact([
    for k in local.tc_bootstrap_keys :
    trimspace(lookup(var.tc_bootstrap_options, k, "")) != "" ? "${k}=${trimspace(var.tc_bootstrap_options[k])}" : ""
  ]))
}

# ---------------------------------------------------------------- IAM (tc_project bootstrap module)
resource "aws_iam_role" "tc_vm" {
  count = local.tc
  name  = var.tc_instance_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_instance_profile" "tc_vm" {
  count = local.tc
  name  = "${var.tc_instance_role_name}-profile"
  role  = aws_iam_role.tc_vm[0].name
}

# ---------------------------------------------------------------- IAM (tc_iam_project)
variable "tc_cluster_role_test_principals" {
  description = "TEST ONLY: extra IAM principal ARNs allowed to assume the cluster role (e.g. your IAM user, to mint STS credentials for a credentials-file test). Keep empty normally."
  type        = list(string)
  default     = []
}

resource "aws_iam_role" "tc_cluster" {
  count = local.tc
  name  = var.tc_cluster_role_name

  # 12 h so STS credentials minted for a test last longer than the 1 h default.
  max_session_duration = 43200

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = concat([aws_iam_role.tc_vm[0].arn], var.tc_cluster_role_test_principals) }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "tc_cluster" {
  count       = local.tc
  name        = var.tc_cluster_policy_name
  description = "Prisma AIRS tag collector: read EKS cluster details (from SCM tc_iam_project)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Copied from the SCM template as-is (broad). Tighten once PANW confirms what it needs.
        Effect   = "Allow"
        Action   = "s3:*"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:AccessKubernetesApi",
          "sts:GetCallerIdentity",
          "eks:ListClusters",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "tc_cluster" {
  count      = local.tc
  role       = aws_iam_role.tc_cluster[0].name
  policy_arn = aws_iam_policy.tc_cluster[0].arn
}

# ---------------------------------------------------------------- EKS access (not in SCM template)
# IAM alone does not grant Kubernetes API access on EKS: map the roles to the
# read-only AmazonEKSViewPolicy. The instance role is mapped too in case the
# TC calls the API without assuming the cluster role.
locals {
  tc_eks_principals = var.enable_tag_collector ? {
    cluster_role  = aws_iam_role.tc_cluster[0].arn
    instance_role = aws_iam_role.tc_vm[0].arn
  } : {}
}

resource "aws_eks_access_entry" "tc" {
  for_each      = local.tc_eks_principals
  cluster_name  = module.eks.cluster_name
  principal_arn = each.value
}

resource "aws_eks_access_policy_association" "tc" {
  for_each      = local.tc_eks_principals
  cluster_name  = module.eks.cluster_name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.tc]
}

# ---------------------------------------------------------------- network
resource "aws_security_group" "tc_mgmt" {
  count       = local.tc
  name        = "${var.name}-tc-mgmt"
  description = "Prisma AIRS tag collector management"
  vpc_id      = module.vpc.vpc_id
  tags        = { Name = "${var.name}-tc-mgmt" }
}

# SCM template opens 443/22 from 0.0.0.0/0; restricted to admin_cidrs here.
resource "aws_vpc_security_group_ingress_rule" "tc_mgmt_https" {
  for_each          = var.enable_tag_collector ? toset(var.admin_cidrs) : toset([])
  security_group_id = aws_security_group.tc_mgmt[0].id
  description       = "HTTPS from admin"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "tc_mgmt_ssh" {
  for_each          = var.enable_tag_collector ? toset(var.admin_cidrs) : toset([])
  security_group_id = aws_security_group.tc_mgmt[0].id
  description       = "SSH from admin"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_egress_rule" "tc_mgmt_all" {
  count             = local.tc
  security_group_id = aws_security_group.tc_mgmt[0].id
  description       = "To SCM, IP-tag service, EKS API"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Firewall (redistribution client) -> tag collector (redistribution agent), User-ID
# redistribution port 5007. The firewall connects from its management interface.
resource "aws_vpc_security_group_ingress_rule" "tc_redistribution_from_fw" {
  count                        = local.tc
  security_group_id            = aws_security_group.tc_mgmt[0].id
  description                  = "IP-tag redistribution from Prisma AIRS firewall mgmt"
  referenced_security_group_id = aws_security_group.fw_mgmt.id
  ip_protocol                  = "tcp"
  from_port                    = 5007
  to_port                      = 5007
}

# TC -> EKS API private endpoint (the module's cluster SG only allows the nodes).
resource "aws_vpc_security_group_ingress_rule" "eks_api_from_tc" {
  count                        = local.tc
  security_group_id            = module.eks.cluster_security_group_id
  description                  = "EKS API from Prisma AIRS tag collector"
  referenced_security_group_id = aws_security_group.tc_mgmt[0].id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_network_interface" "tc_mgmt" {
  count           = local.tc
  subnet_id       = aws_subnet.mgmt.id
  private_ips     = [local.tc_mgmt_ip]
  security_groups = [aws_security_group.tc_mgmt[0].id]
  tags            = { Name = "${var.name}-tc-mgmt" }
}

resource "aws_eip" "tc_mgmt" {
  count                     = local.tc
  domain                    = "vpc"
  network_interface         = aws_network_interface.tc_mgmt[0].id
  associate_with_private_ip = local.tc_mgmt_ip
  tags                      = { Name = "${var.name}-tc-mgmt" }

  depends_on = [module.vpc]
}

# ---------------------------------------------------------------- instance
resource "aws_instance" "tc" {
  count                = local.tc
  ami                  = var.tc_ami_id != "" ? var.tc_ami_id : data.aws_ami.fw.id
  instance_type        = var.tc_instance_type
  key_name             = var.ssh_key_name
  iam_instance_profile = aws_iam_instance_profile.tc_vm[0].name
  user_data            = local.tc_user_data

  network_interface {
    network_interface_id = aws_network_interface.tc_mgmt[0].id
    device_index         = 0
  }

  root_block_device {
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = "${var.name}-tag-collector" }

  lifecycle {
    ignore_changes = [user_data]

    precondition {
      condition     = length(regexall("tag_collector_mode_flag:enable", lookup(var.tc_bootstrap_options, "plugin-op-commands", ""))) > 0
      error_message = "tc_bootstrap_options.plugin-op-commands must contain tag_collector_mode_flag:enable (copy it from the SCM template)."
    }
    precondition {
      condition     = !anytrue([for v in values(var.tc_bootstrap_options) : can(regex("[<>]", v))])
      error_message = "tc_bootstrap_options still contains a placeholder like <AUTH_CODE>, <PIN_ID> or <TSG_ID>: copy the real values from the SCM template."
    }
    precondition {
      condition = alltrue([for k in ["authcodes", "vm-series-auto-registration-pin-id", "vm-series-auto-registration-pin-value", "tsg-id", "tplname", "dgname", "discovery-account-id", "ip-tag-svc-endpoint"] :
      trimspace(lookup(var.tc_bootstrap_options, k, "")) != ""])
      error_message = "tc_bootstrap_options is missing SCM-generated values (authcodes, PIN, tsg-id, tplname, dgname, discovery-account-id, ip-tag-svc-endpoint)."
    }
  }
}

output "tag_collector_mgmt_public_ip" {
  description = "Tag collector management public IP (SSH admin@<ip>)."
  value       = local.tc == 1 ? aws_eip.tc_mgmt[0].public_ip : null
}

output "tag_collector_bootstrap_keys" {
  description = "Bootstrap keys sent to the tag collector (values hidden)."
  value       = [for k in local.tc_bootstrap_keys : k if trimspace(lookup(nonsensitive(var.tc_bootstrap_options), k, "")) != ""]
}
