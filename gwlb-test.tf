# OPTIONAL control test: does vpce -> subinterface association work for
# NON-PAN-CNI traffic (normal GWLB route-table insertion)?
#
#   test EC2 (10.20.253.0/28) --route 0/0--> GWLBE --> GWLB --GENEVE--> FW
#        FW --> GWLB --> GWLBE --(inspection RT 0/0)--> NAT --> internet
#   return: NAT --(public RT 10.20.253.0/28 -> GWLBE)--> GWLBE --> FW --> test EC2
#
# The EC2 needs no SSH/SSM: user_data curls http://example.com every 3 s.
# On the firewall:  show session all filter source <test_ec2_ip>
#   zone <subinterface-zone> / ingress ethernet1/1.10  -> association works, PAN CNI path ignores it
#   zone LAN       / ingress ethernet1/1     -> association does not work on this FW at all
#
# Enable:  terraform apply -var enable_gwlb_test=true
# Remove:  terraform apply                      (variable defaults to false)

variable "enable_gwlb_test" {
  description = "Create the GWLB association control test (test subnet, routes, 1 x t3.micro)."
  type        = bool
  default     = false
}

variable "gwlb_test_subnet_cidr" {
  description = "Test subnet whose default route points at the GWLB endpoint."
  type        = string
  default     = "10.20.253.0/28"
}

locals {
  gwlb_test = var.enable_gwlb && var.enable_gwlb_test ? 1 : 0
}

resource "aws_subnet" "gwlb_test" {
  count = local.gwlb_test

  vpc_id            = module.vpc.vpc_id
  cidr_block        = var.gwlb_test_subnet_cidr
  availability_zone = local.fw_az

  tags = { Name = "${var.name}-gwlb-test" }
}

resource "aws_route_table" "gwlb_test" {
  count  = local.gwlb_test
  vpc_id = module.vpc.vpc_id

  tags = { Name = "${var.name}-gwlb-test" }
}

# Everything leaving the test subnet (except VPC local) goes through the GWLBE.
resource "aws_route" "gwlb_test_default" {
  count = local.gwlb_test

  route_table_id         = aws_route_table.gwlb_test[0].id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = aws_vpc_endpoint.gwlbe[0].id
}

resource "aws_route_table_association" "gwlb_test" {
  count = local.gwlb_test

  subnet_id      = aws_subnet.gwlb_test[0].id
  route_table_id = aws_route_table.gwlb_test[0].id
}

# Return path symmetry: replies coming back through the NAT gateway (public
# subnet) to the test subnet must also go through the GWLBE.
resource "aws_route" "gwlb_test_return" {
  count = local.gwlb_test

  route_table_id         = module.vpc.public_route_table_ids[0]
  destination_cidr_block = var.gwlb_test_subnet_cidr
  vpc_endpoint_id        = aws_vpc_endpoint.gwlbe[0].id
}

resource "aws_security_group" "gwlb_test" {
  count = local.gwlb_test

  name_prefix = "${var.name}-gwlb-test-"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-gwlb-test" }
}

data "aws_ssm_parameter" "al2023" {
  count = local.gwlb_test
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "gwlb_test" {
  count = local.gwlb_test

  ami                    = nonsensitive(data.aws_ssm_parameter.al2023[0].value)
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.gwlb_test[0].id
  vpc_security_group_ids = [aws_security_group.gwlb_test[0].id]

  user_data = <<-EOT
    #!/bin/bash
    nohup bash -c 'while true; do curl -s -o /dev/null -m 5 http://example.com; sleep 3; done' >/dev/null 2>&1 &
  EOT

  tags = { Name = "${var.name}-gwlb-test" }

  depends_on = [aws_route.gwlb_test_default, aws_route.gwlb_test_return]
}

output "gwlb_test_ec2_ip" {
  description = "Private IP of the control-test EC2 (filter sessions on the FW by this source)."
  value       = local.gwlb_test == 1 ? aws_instance.gwlb_test[0].private_ip : null
}
