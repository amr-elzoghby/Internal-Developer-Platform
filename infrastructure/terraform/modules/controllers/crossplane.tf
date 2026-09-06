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

  # Crossplane v2 otherwise activates every ManagedResourceDefinition shipped
  # by every provider. The platform applies an exact MRAP before providers.
  set {
    name  = "provider.defaultActivations"
    value = "{}"
  }
}

