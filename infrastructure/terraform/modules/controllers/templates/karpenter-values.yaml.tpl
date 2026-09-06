# ─── Karpenter Helm Values ────────────────────────────────────────────────────
settings:
  clusterName: "${cluster_name}"
  clusterEndpoint: "${cluster_endpoint}"
  interruptionQueue: "${queue_name}"

nodeSelector:
  role: stable

tolerations:
  - key: CriticalAddonsOnly
    operator: Exists

replicas: 2
podDisruptionBudget:
  maxUnavailable: 1
controller:
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 1
      memory: 1Gi
