variable "aws_region" { type = string }
variable "vpc_id" { type = string }
variable "load_balancer_controller_role_arn" { type = string }

resource "helm_release" "load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.5.0"
  namespace  = "kube-system"

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  wait_for_jobs   = true
  timeout         = 600

  values = [yamlencode({
    clusterName  = var.cluster_name
    region       = var.aws_region
    vpcId        = var.vpc_id
    replicaCount = 2
    serviceAccount = {
      create      = true
      name        = "aws-load-balancer-controller"
      annotations = { "eks.amazonaws.com/role-arn" = var.load_balancer_controller_role_arn }
    }
    nodeSelector        = { role = "stable" }
    tolerations         = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
    podDisruptionBudget = { maxUnavailable = 1 }
    resources = {
      requests = { cpu = "200m", memory = "256Mi" }
      limits   = { cpu = "500m", memory = "512Mi" }
    }
    topologySpreadConstraints = [{
      maxSkew           = 1
      topologyKey       = "kubernetes.io/hostname"
      whenUnsatisfiable = "DoNotSchedule"
      labelSelector = { matchLabels = {
        "app.kubernetes.io/name"     = "aws-load-balancer-controller"
        "app.kubernetes.io/instance" = "aws-load-balancer-controller"
      } }
    }]
  })]
}
