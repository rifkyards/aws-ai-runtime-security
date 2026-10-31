output "region" {
  value = var.region
}

output "kubeconfig_command" {
  description = "Run this to use kubectl against the new cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "fw_mgmt_public_ip" {
  description = "Firewall management (GUI https:// and ssh admin@)."
  value       = aws_eip.fw_mgmt.public_ip
}

output "pan_cni_endpoint" {
  description = "IP that PAN CNI sends pod traffic to (GWLBE IP, or FW data IP without GWLB)."
  value       = local.pan_cni_endpoint
}

output "gwlb_target_group_arn" {
  description = "Check target health: aws elbv2 describe-target-health --target-group-arn <this>"
  value       = var.enable_gwlb ? aws_lb_target_group.fw[0].arn : null
}

output "fw_data_ip" {
  description = "Firewall data IP (ethernet1/1). PAN CNI endpoint."
  value       = local.fw_data_ip
}

output "scm_config_values" {
  description = "Values to enter in Strata Cloud Manager for the firewall folder."
  value = {
    "ethernet1/1 type"            = "Layer3, DHCP client (AWS will hand out ${local.fw_data_ip}) or static ${local.fw_data_ip}/${split("/", var.inspection_subnet_cidr)[1]}"
    "ethernet1/1 zone"            = "trust"
    "ethernet1/1 mgmt profile"    = "HTTPS + ping"
    "logical router"              = "lr-private (ethernet1/1)"
    "static route vpc"            = "${var.vpc_cidr} -> next hop ${local.inspection_gateway_ip} (ethernet1/1)"
    "static route default"        = "0.0.0.0/0 -> next hop ${local.inspection_gateway_ip} (ethernet1/1)"
    "NAT (east-west, per PA doc)" = "trust -> trust, destination ${var.vpc_cidr}, source translation dynamic-ip-and-port, interface ethernet1/1"
    "pod CIDR (AWS VPC CNI)"      = join(", ", module.vpc.private_subnets_cidr_blocks)
  }
}

output "bootstrap_user_data_keys" {
  description = "Bootstrap keys that were sent to the firewall (values hidden)."
  value       = nonsensitive([for kv in split(";", local.bootstrap_user_data) : split("=", kv)[0]])
}
