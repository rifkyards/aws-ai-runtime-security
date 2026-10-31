# PAN CNI: the EndpointSlice behind service pan-ngfw-svc (UDP 6080) holds the
# GWLB endpoint IP (enable_gwlb = true) or the firewall data IP (false).
# Chart vendored from github.com/PaloAltoNetworks/prisma-airs-helm (MIT),
# see charts/ai-runtime-security/UPSTREAM_COMMIT.
resource "helm_release" "pan_cni" {
  count = var.install_pan_cni ? 1 : 0

  name      = "ai-runtime-security"
  chart     = "${path.module}/charts/ai-runtime-security"
  namespace = "kube-system"

  values = [yamlencode({
    endpoints   = local.pan_cni_endpoint
    cniimage    = var.pan_cni_image
    fwtrustcidr = var.inspection_subnet_cidr
    namespace   = "kube-system"
    clusterid   = var.cluster_id
    deployTo    = "eks"
  })]

  wait    = true
  timeout = 300

  depends_on = [
    module.eks,
    aws_instance.fw,
    aws_lb_listener.gwlb,
    aws_lb_target_group_attachment.fw,
  ]
}
