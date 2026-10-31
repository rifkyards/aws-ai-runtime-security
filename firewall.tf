# Fails at plan time with a clear error if the AMI does not exist in var.region
# (AMI IDs are regional) or the account cannot see it (Marketplace not subscribed).
data "aws_ami" "fw" {
  filter {
    name   = "image-id"
    values = [var.fw_ami_id]
  }
}

locals {
  # Same keys and order as the existing bootstrap_options block; empty values are skipped.
  bootstrap_keys = [
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
  ]

  bootstrap_user_data = join(";", compact([
    for k in local.bootstrap_keys :
    trimspace(lookup(var.bootstrap_options, k, "")) != "" ? "${k}=${trimspace(var.bootstrap_options[k])}" : ""
  ]))
}

# ---------------------------------------------------------------- security groups
resource "aws_security_group" "fw_mgmt" {
  name        = "${var.name}-fw-mgmt"
  description = "Prisma AIRS firewall management (eth0)"
  vpc_id      = module.vpc.vpc_id
  tags        = { Name = "${var.name}-fw-mgmt" }
}

resource "aws_vpc_security_group_ingress_rule" "fw_mgmt_https" {
  for_each          = toset(var.admin_cidrs)
  security_group_id = aws_security_group.fw_mgmt.id
  description       = "HTTPS from admin"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "fw_mgmt_ssh" {
  for_each          = toset(var.admin_cidrs)
  security_group_id = aws_security_group.fw_mgmt.id
  description       = "SSH from admin"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_egress_rule" "fw_mgmt_all" {
  security_group_id = aws_security_group.fw_mgmt.id
  description       = "Outbound to Strata Cloud Manager, licensing, updates"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "fw_data" {
  name        = "${var.name}-fw-data"
  description = "Prisma AIRS firewall data interface (eth1): receives PAN CNI traffic"
  vpc_id      = module.vpc.vpc_id
  tags        = { Name = "${var.name}-fw-data" }
}

# Covers PAN CNI encapsulated traffic (UDP 6080) from the nodes, the decapsulated
# pod flows, and HTTPS/ping to the interface management profile.
# Tighten to UDP 6080 from the node SG + HTTPS/ICMP once the PoC works.
resource "aws_vpc_security_group_ingress_rule" "fw_data_from_vpc" {
  security_group_id = aws_security_group.fw_data.id
  description       = "All traffic from inside the VPC (nodes and pods)"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "fw_data_all" {
  security_group_id = aws_security_group.fw_data.id
  description       = "Forward inspected traffic"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------- interfaces
resource "aws_network_interface" "fw_mgmt" {
  subnet_id       = aws_subnet.mgmt.id
  private_ips     = [local.fw_mgmt_ip]
  security_groups = [aws_security_group.fw_mgmt.id]
  tags            = { Name = "${var.name}-fw-eth0-mgmt" }
}

resource "aws_network_interface" "fw_data" {
  subnet_id       = aws_subnet.inspection.id
  private_ips     = [local.fw_data_ip]
  security_groups = [aws_security_group.fw_data.id]

  # The firewall forwards packets whose IPs are not its own.
  source_dest_check = false

  tags = { Name = "${var.name}-fw-eth1-data" }
}

resource "aws_eip" "fw_mgmt" {
  domain                    = "vpc"
  network_interface         = aws_network_interface.fw_mgmt.id
  associate_with_private_ip = local.fw_mgmt_ip
  tags                      = { Name = "${var.name}-fw-mgmt" }

  depends_on = [module.vpc]
}

# ---------------------------------------------------------------- instance
resource "aws_instance" "fw" {
  ami           = data.aws_ami.fw.id
  instance_type = var.fw_instance_type
  key_name      = var.ssh_key_name
  user_data     = local.bootstrap_user_data

  network_interface {
    network_interface_id = aws_network_interface.fw_mgmt.id
    device_index         = 0
  }

  network_interface {
    network_interface_id = aws_network_interface.fw_data.id
    device_index         = 1
  }

  root_block_device {
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = "${var.name}-fw" }

  lifecycle {
    # Bootstrap only runs on first boot; editing bootstrap_options later must
    # not stop/start the running firewall.
    ignore_changes = [user_data]

    precondition {
      condition     = !anytrue([for v in values(var.bootstrap_options) : can(regex("[<>]", v))])
      error_message = "bootstrap_options still contains a placeholder like <AUTH_CODE> or <PIN_ID>: replace it with the real value."
    }
    precondition {
      condition     = lookup(var.bootstrap_options, "authcodes", "") != ""
      error_message = "bootstrap_options.authcodes is empty: set the Prisma AIRS auth code (deployment profile) in terraform.tfvars."
    }
    precondition {
      condition = (
        lookup(var.bootstrap_options, "vm-series-auto-registration-pin-id", "") != "" &&
        lookup(var.bootstrap_options, "vm-series-auto-registration-pin-value", "") != ""
      )
      error_message = "Set vm-series-auto-registration-pin-id and -pin-value (device certificate PIN) in bootstrap_options."
    }
    precondition {
      condition     = lookup(var.bootstrap_options, "panorama-server", "") != "cloud" || lookup(var.bootstrap_options, "dgname", "") != ""
      error_message = "With panorama-server=cloud (Strata Cloud Manager), dgname must be set to the SCM folder name."
    }
  }
}
