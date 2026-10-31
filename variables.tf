# ---------------------------------------------------------------- general
variable "region" {
  description = "AWS region. ap-southeast-3 = Jakarta (opt-in region: enable it in the account first)."
  type        = string
  default     = "ap-southeast-3"
}

variable "name" {
  description = "Name prefix for every resource (also the EKS cluster name)."
  type        = string
  default     = "airs-eks"
}

variable "tags" {
  description = "Tags applied to every AWS resource."
  type        = map(string)
  default = {
    Project   = "prisma-airs-eks-direct"
    ManagedBy = "terraform"
  }
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach the firewall management interface and the EKS public API endpoint (your office/VPN public IP, e.g. [\"203.0.113.10/32\"])."
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0
    error_message = "admin_cidrs must contain at least one CIDR."
  }
}

variable "eks_public_access_cidrs" {
  description = "CIDRs allowed to reach the EKS public API endpoint. 0.0.0.0/0 is workable when the admin IP keeps changing (e.g. Cloudflare WARP): requests still need valid IAM credentials and an EKS access entry."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ---------------------------------------------------------------- network
variable "vpc_cidr" {
  description = "VPC CIDR. Node subnets, public subnets, inspection and mgmt subnets are carved from it."
  type        = string
  default     = "10.20.0.0/16"
}

variable "inspection_subnet_cidr" {
  description = "Side subnet that holds the firewall data interface (eth1 / ethernet1/1). Must be inside vpc_cidr and not overlap other subnets."
  type        = string
  default     = "10.20.250.0/28"
}

variable "mgmt_subnet_cidr" {
  description = "Subnet for the firewall management interface (eth0). Routed to the internet gateway so the firewall can reach Strata Cloud Manager."
  type        = string
  default     = "10.20.251.0/28"
}

variable "enable_gwlb" {
  description = "Put a Gateway Load Balancer + GWLB endpoint in front of the firewall (PAN CNI sends to the GWLBE IP). false = PAN CNI sends straight to the firewall data IP."
  type        = bool
  default     = true
}

variable "gwlbe_subnet_cidr" {
  description = "Subnet for the GWLB endpoint (same AZ as the firewall). Only used when enable_gwlb = true."
  type        = string
  default     = "10.20.252.0/28"
}

variable "fw_data_ip" {
  description = "Static private IP of the firewall data interface. This is the IP PAN CNI sends pod traffic to. Empty = 10th host of inspection_subnet_cidr."
  type        = string
  default     = ""
}

variable "fw_mgmt_ip" {
  description = "Static private IP of the firewall management interface. Empty = 10th host of mgmt_subnet_cidr."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------- EKS
variable "kubernetes_version" {
  description = "EKS Kubernetes version (PAN CNI needs 1.30+)."
  type        = string
  default     = "1.34"
}

variable "node_instance_type" {
  description = "Instance type for the EKS managed node group."
  type        = string
  default     = "m5.large"
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

# ---------------------------------------------------------------- firewall
variable "fw_ami_id" {
  description = "Prisma AIRS AI Runtime Firewall AMI in var.region (subscribe in AWS Marketplace first)."
  type        = string
  default     = "ami-0ac089e9d177c663d"
}

variable "fw_instance_type" {
  description = "Firewall instance type (Prisma AIRS needs at least 4 vCPU)."
  type        = string
  default     = "m5.xlarge"
}

variable "ssh_key_name" {
  description = "Existing EC2 key pair name in var.region, used for SSH to the firewall (user: admin)."
  type        = string
}

variable "bootstrap_options" {
  description = <<-EOT
    VM-Series bootstrap key/values passed as EC2 user data (joined with ";").
    Keys with an empty value are left out. For Strata Cloud Manager:
      panorama-server = "cloud"
      dgname          = "<SCM folder name>"
    With enable_gwlb = true use plugin-op-commands = "advance-routing:enable,aws-gwlb-inspect:enable"
    (bootstrap only applies on a fresh instance; on a running firewall use the CLI:
    request plugins vm_series aws gwlb inspect enable yes).
    Do not enable aws-gwlb-overlay-routing: single-interface design.
  EOT
  type        = map(string)
  sensitive   = true # hides auth code / PIN in plan output

  default = {
    "mgmt-interface-swap"                   = "disable"
    "plugin-op-commands"                    = "advance-routing:enable"
    "vm-auth-key"                           = ""
    "dgname"                                = ""
    "tplname"                               = ""
    "dhcp-send-hostname"                    = "yes"
    "dhcp-send-client-id"                   = "yes"
    "dhcp-accept-server-hostname"           = "yes"
    "dhcp-accept-server-domain"             = "yes"
    "panorama-server"                       = "cloud"
    "authcodes"                             = ""
    "vm-series-auto-registration-pin-id"    = ""
    "vm-series-auto-registration-pin-value" = ""
  }

  validation {
    condition     = !can(regex("aws-gwlb-overlay-routing", lookup(var.bootstrap_options, "plugin-op-commands", "")))
    error_message = "Do not enable aws-gwlb-overlay-routing: the firewall has a single data interface."
  }
}

# ---------------------------------------------------------------- PAN CNI
variable "install_pan_cni" {
  description = "Install the PAN CNI Helm chart. It does nothing until a namespace is annotated paloaltonetworks.com/firewall=pan-fw."
  type        = bool
  default     = true
}

variable "pan_cni_image" {
  description = "PAN CNI container image (pinned to the tag in the upstream chart)."
  type        = string
  default     = "gcr.io/pan-cn-series/airs/pan-cni:4.0.0"
}

variable "cluster_id" {
  description = "Kubernetes cluster ID for PAN CNI (1-2048, unique per cluster sending to the same firewall)."
  type        = number
  default     = 1

  validation {
    condition     = var.cluster_id >= 1 && var.cluster_id <= 2048
    error_message = "cluster_id must be between 1 and 2048."
  }
}
