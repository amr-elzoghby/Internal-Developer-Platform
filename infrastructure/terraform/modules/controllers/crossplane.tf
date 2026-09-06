resource "helm_release" "crossplane" {
  name       = "crossplane"
  repository = "https://charts.crossplane.io/stable"
  chart      = "crossplane"
  version    = var.crossplane_version
  namespace  = "crossplane-system"

  create_namespace = true
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  wait_for_jobs    = true
  timeout          = 600

  values = [yamlencode({
    replicas       = 2
    leaderElection = true
    nodeSelector   = { role = "stable" }
    tolerations    = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
    topologySpreadConstraints = [{
      maxSkew       = 1, topologyKey = "kubernetes.io/hostname", whenUnsatisfiable = "DoNotSchedule"
      labelSelector = { matchLabels = { app = "crossplane", release = "crossplane" } }
    }]
    rbacManager = {
      replicas       = 2
      leaderElection = true
      nodeSelector   = { role = "stable" }
      tolerations    = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
      topologySpreadConstraints = [{
        maxSkew       = 1, topologyKey = "kubernetes.io/hostname", whenUnsatisfiable = "DoNotSchedule"
        labelSelector = { matchLabels = { app = "crossplane-rbac-manager", release = "crossplane" } }
      }]
    }
    extraObjects = [for name in ["crossplane", "crossplane-rbac-manager"] : {
      apiVersion = "policy/v1"
      kind       = "PodDisruptionBudget"
      metadata   = { name = name, namespace = "crossplane-system" }
      spec = {
        maxUnavailable = 1
        selector       = { matchLabels = { app = name, release = "crossplane" } }
      }
    }]
  })]

  # Crossplane v2 otherwise activates every ManagedResourceDefinition shipped
  # by every provider. The platform applies an exact MRAP before providers.
  set {
    name  = "provider.defaultActivations"
    value = "{}"
  }
}

