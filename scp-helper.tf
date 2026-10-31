# TEMPORARY SCP source for the tag collector's `scp import k8s-service-account`.
#
# PAN-OS `scp import` PULLS a file from an SCP server it can reach, with a password.
# Your laptop is behind NAT, so this small EC2 in the mgmt subnet holds the file.
#
#   terraform apply -var enable_tag_collector=true -var enable_scp_helper=true \
#                   -var 'scp_helper_password=<strong-password>'
#   scp -i <key>.pem <file> ec2-user@$(terraform output -raw scp_helper_public_ip):~
#   (tag collector) scp import k8s-service-account from ec2-user@<scp_helper_private_ip>:/home/ec2-user/<file>
#
# Remove right after the import:  terraform apply -var enable_tag_collector=true

variable "enable_scp_helper" {
  description = "Create the temporary SCP helper EC2 (needs enable_tag_collector)."
  type        = bool
  default     = false
}

variable "scp_helper_password" {
  description = "Password for ec2-user on the SCP helper (PAN-OS scp import asks for a password)."
  type        = string
  default     = ""
  sensitive   = true
}

locals {
  scp_helper = var.enable_scp_helper && var.enable_tag_collector ? 1 : 0
}

resource "aws_security_group" "scp_helper" {
  count       = local.scp_helper
  name        = "${var.name}-scp-helper"
  description = "Temporary SCP source for the tag collector"
  vpc_id      = module.vpc.vpc_id
  tags        = { Name = "${var.name}-scp-helper" }
}

resource "aws_vpc_security_group_ingress_rule" "scp_helper_admin" {
  for_each          = local.scp_helper == 1 ? toset(var.admin_cidrs) : toset([])
  security_group_id = aws_security_group.scp_helper[0].id
  description       = "SSH/SCP upload from admin"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "scp_helper_from_tc" {
  count                        = local.scp_helper
  security_group_id            = aws_security_group.scp_helper[0].id
  description                  = "SCP pull from the tag collector"
  referenced_security_group_id = aws_security_group.tc_mgmt[0].id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
}

resource "aws_vpc_security_group_egress_rule" "scp_helper_all" {
  count             = local.scp_helper
  security_group_id = aws_security_group.scp_helper[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

data "aws_ssm_parameter" "scp_helper_al2023" {
  count = local.scp_helper
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "scp_helper" {
  count                       = local.scp_helper
  ami                         = nonsensitive(data.aws_ssm_parameter.scp_helper_al2023[0].value)
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.mgmt.id
  vpc_security_group_ids      = [aws_security_group.scp_helper[0].id]
  key_name                    = var.ssh_key_name
  associate_public_ip_address = true

  # Password login for ec2-user (PAN-OS scp import is password-only). The 00- drop-in
  # wins over AL2023's 50-cloud-init.conf (sshd keeps the first value it reads).
  user_data = <<-EOT
    #!/bin/bash
    echo 'ec2-user:${var.scp_helper_password}' | chpasswd
    echo 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/00-scp-helper.conf
    systemctl restart sshd
  EOT

  tags = { Name = "${var.name}-scp-helper" }

  lifecycle {
    precondition {
      condition     = length(var.scp_helper_password) >= 12
      error_message = "Set scp_helper_password (at least 12 characters)."
    }
  }
}

output "scp_helper_public_ip" {
  description = "Upload target from your laptop (scp -i <key>.pem ... ec2-user@<ip>:~)."
  value       = local.scp_helper == 1 ? aws_instance.scp_helper[0].public_ip : null
}

output "scp_helper_private_ip" {
  description = "Source for `scp import` on the tag collector."
  value       = local.scp_helper == 1 ? aws_instance.scp_helper[0].private_ip : null
}
