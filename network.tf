data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Firewall lives in the first AZ (single firewall, no GWLB).
  fw_az = local.azs[0]

  fw_data_ip = var.fw_data_ip != "" ? var.fw_data_ip : cidrhost(var.inspection_subnet_cidr, 10)
  fw_mgmt_ip = var.fw_mgmt_ip != "" ? var.fw_mgmt_ip : cidrhost(var.mgmt_subnet_cidr, 10)

  # AWS reserves the subnet's .1 as the VPC router: this is the next hop
  # to use for static routes on the firewall's logical router.
  inspection_gateway_ip = cidrhost(var.inspection_subnet_cidr, 1)
}

# VPC with two private subnets for EKS nodes (pods get VPC IPs from these,
# because the AWS VPC CNI is used), two public subnets and one NAT gateway.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.16"

  name = var.name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for i in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 4, i)]         # /20 each
  public_subnets  = [for i in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 8, 100 + i)]   # /24 each

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

# ---------------------------------------------------------------- inspection subnet (firewall data, eth1)
resource "aws_subnet" "inspection" {
  vpc_id            = module.vpc.vpc_id
  cidr_block        = var.inspection_subnet_cidr
  availability_zone = local.fw_az

  tags = { Name = "${var.name}-inspection" }
}

resource "aws_route_table" "inspection" {
  vpc_id = module.vpc.vpc_id
  tags   = { Name = "${var.name}-inspection" }
}

# Internet-bound traffic that the firewall forwards leaves through the NAT gateway.
resource "aws_route" "inspection_default" {
  route_table_id         = aws_route_table.inspection.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = module.vpc.natgw_ids[0]
}

resource "aws_route_table_association" "inspection" {
  subnet_id      = aws_subnet.inspection.id
  route_table_id = aws_route_table.inspection.id
}

# ---------------------------------------------------------------- mgmt subnet (firewall eth0)
resource "aws_subnet" "mgmt" {
  vpc_id            = module.vpc.vpc_id
  cidr_block        = var.mgmt_subnet_cidr
  availability_zone = local.fw_az

  tags = { Name = "${var.name}-fw-mgmt" }
}

resource "aws_route_table" "mgmt" {
  vpc_id = module.vpc.vpc_id
  tags   = { Name = "${var.name}-fw-mgmt" }
}

# Management reaches Strata Cloud Manager / licensing through the internet gateway (with an EIP).
resource "aws_route" "mgmt_default" {
  route_table_id         = aws_route_table.mgmt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = module.vpc.igw_id
}

resource "aws_route_table_association" "mgmt" {
  subnet_id      = aws_subnet.mgmt.id
  route_table_id = aws_route_table.mgmt.id
}

# Note: no route changes are needed in the node subnets. Nodes reach the
# firewall data IP through the VPC "local" route; PAN CNI does the steering.
