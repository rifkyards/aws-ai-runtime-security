# Gateway Load Balancer in front of the Prisma AIRS firewall, same VPC.
#
#   pod --(PAN CNI, UDP 6080)--> GWLB endpoint IP --> GWLB --(GENEVE 6081)--> FW eth1
#
# The firewall is registered by IP (its eth1 / ethernet1/1 address), so GWLB
# sends GENEVE to the data interface directly: no mgmt-interface-swap needed.
# The firewall must have GWLB inspection enabled:
#   request plugins vm_series aws gwlb inspect enable yes

data "aws_caller_identity" "current" {}

resource "aws_subnet" "gwlbe" {
  count = var.enable_gwlb ? 1 : 0

  vpc_id            = module.vpc.vpc_id
  cidr_block        = var.gwlbe_subnet_cidr
  availability_zone = local.fw_az

  tags = { Name = "${var.name}-gwlbe" }
}

resource "aws_route_table_association" "gwlbe" {
  count = var.enable_gwlb ? 1 : 0

  subnet_id      = aws_subnet.gwlbe[0].id
  route_table_id = aws_route_table.inspection.id
}

resource "aws_lb" "gwlb" {
  count = var.enable_gwlb ? 1 : 0

  name               = "${var.name}-gwlb"
  load_balancer_type = "gateway"
  subnets            = [aws_subnet.inspection.id]

  tags = { Name = "${var.name}-gwlb" }
}

resource "aws_lb_target_group" "fw" {
  count = var.enable_gwlb ? 1 : 0

  name        = "${var.name}-fw"
  port        = 6081
  protocol    = "GENEVE"
  target_type = "ip"
  vpc_id      = module.vpc.vpc_id

  # Answered by the firewall data interface: needs an interface management
  # profile with HTTPS on ethernet1/1.
  health_check {
    protocol            = "TCP"
    port                = "443"
    interval            = 10
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.name}-fw" }
}

resource "aws_lb_target_group_attachment" "fw" {
  count = var.enable_gwlb ? 1 : 0

  target_group_arn = aws_lb_target_group.fw[0].arn
  target_id        = local.fw_data_ip
  port             = 6081
}

resource "aws_lb_listener" "gwlb" {
  count = var.enable_gwlb ? 1 : 0

  load_balancer_arn = aws_lb.gwlb[0].arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.fw[0].arn
  }
}

resource "aws_vpc_endpoint_service" "gwlb" {
  count = var.enable_gwlb ? 1 : 0

  acceptance_required        = false
  gateway_load_balancer_arns = [aws_lb.gwlb[0].arn]

  tags = { Name = "${var.name}-gwlb" }
}

resource "aws_vpc_endpoint_service_allowed_principal" "self" {
  count = var.enable_gwlb ? 1 : 0

  vpc_endpoint_service_id = aws_vpc_endpoint_service.gwlb[0].id
  principal_arn           = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
}

resource "aws_vpc_endpoint" "gwlbe" {
  count = var.enable_gwlb ? 1 : 0

  vpc_id            = module.vpc.vpc_id
  service_name      = aws_vpc_endpoint_service.gwlb[0].service_name
  vpc_endpoint_type = "GatewayLoadBalancer"
  subnet_ids        = [aws_subnet.gwlbe[0].id]

  tags = { Name = "${var.name}-gwlbe" }

  depends_on = [aws_vpc_endpoint_service_allowed_principal.self]
}

# Private IP of the GWLB endpoint ENI: this is what PAN CNI sends to.
data "aws_network_interface" "gwlbe" {
  count = var.enable_gwlb ? 1 : 0
  id    = one(aws_vpc_endpoint.gwlbe[0].network_interface_ids)
}

locals {
  pan_cni_endpoint = var.enable_gwlb ? data.aws_network_interface.gwlbe[0].private_ip : local.fw_data_ip
}
