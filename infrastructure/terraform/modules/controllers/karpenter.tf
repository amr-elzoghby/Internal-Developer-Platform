# ─── Karpenter CRDs ─────────────────────────────────────────────────────────
resource "helm_release" "karpenter_crd" {
  name       = "karpenter-crd"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter-crd"
  version    = var.karpenter_version
  namespace  = "kube-system"

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 600

}

# ─── Karpenter Helm Release ──────────────────────────────────────────────────
resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version
  namespace  = "kube-system"
  skip_crds  = true

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 600

  values = [
    templatefile("${path.module}/templates/karpenter-values.yaml.tpl", {
      cluster_name     = var.cluster_name
      cluster_endpoint = var.cluster_endpoint
      queue_name       = var.karpenter_queue_name
    })
  ]

  depends_on = [helm_release.karpenter_crd]
}
