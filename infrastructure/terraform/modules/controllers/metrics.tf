# ─── Metrics Server ──────────────────────────────────────────────────────────
resource "helm_release" "metrics_server" {
  name            = "metrics-server"
  repository      = "https://kubernetes-sigs.github.io/metrics-server/"
  chart           = "metrics-server"
  version         = var.metrics_server_chart_version
  namespace       = "kube-system"
  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 600

  values = [yamlencode({
    replicas            = 2
    nodeSelector        = { role = "stable" }
    tolerations         = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
    podDisruptionBudget = { enabled = true, maxUnavailable = 1 }
    resources = {
      requests = { cpu = "100m", memory = "200Mi" }
      limits   = { cpu = "500m", memory = "400Mi" }
    }
    topologySpreadConstraints = [{
      maxSkew       = 1, topologyKey = "kubernetes.io/hostname", whenUnsatisfiable = "DoNotSchedule"
      labelSelector = { matchLabels = { "app.kubernetes.io/name" = "metrics-server" } }
    }]
  })]
}
