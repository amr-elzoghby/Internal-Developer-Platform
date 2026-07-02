# ─── Karpenter Helm Values ────────────────────────────────────────────────────
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: "${role_arn}"

settings:
  clusterName: "${cluster_name}"
  clusterEndpoint: "${cluster_endpoint}"
  interruptionQueue: "${queue_name}"

nodeSelector:
  role: stable

tolerations:
  - key: CriticalAddonsOnly
    operator: Exists
