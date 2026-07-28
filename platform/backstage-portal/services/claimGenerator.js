function generateClaimYaml(serviceName, claimType, params = {}) {
  const claimId = (params.customClaimName || claimType).toLowerCase().replace(/[^a-z0-9-]/g, '-');
  const secretName = `${serviceName.toLowerCase()}-${claimId}-secret`;

  switch (claimType) {
    case 'postgres':
      return {
        file: `infra/${claimId}-claim.yaml`,
        content: `apiVersion: database.shopscale.io/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: ${serviceName}-${claimId}-claim
  namespace: default
  labels:
    app.kubernetes.io/managed-by: crossplane
    shopscale.io/service: ${serviceName}
spec:
  parameters:
    storageGB: ${params.storageGB || 20}
    engineVersion: "${params.engineVersion || '15'}"
  writeConnectionSecretToRef:
    name: ${secretName}
`
      };
    case 'redis':
      return {
        file: `infra/${claimId}-claim.yaml`,
        content: `apiVersion: cache.shopscale.io/v1alpha1
kind: RedisCacheInstance
metadata:
  name: ${serviceName}-${claimId}-claim
  namespace: default
spec:
  parameters:
    memoryMB: ${params.memoryMB || 512}
    version: "${params.redisVersion || '7.0'}"
  writeConnectionSecretToRef:
    name: ${secretName}
`
      };
    case 's3':
      return {
        file: `infra/${claimId}-claim.yaml`,
        content: `apiVersion: storage.shopscale.io/v1alpha1
kind: S3BucketClaim
metadata:
  name: ${serviceName}-${claimId}-claim
  namespace: default
spec:
  parameters:
    bucketName: ${serviceName.toLowerCase()}-${claimId}-bucket
    acl: ${params.bucketAcl || 'private'}
    versioning: ${params.versioning === 'true' || params.versioning === true ? 'true' : 'false'}
`
      };
    case 'kafka':
      return {
        file: `infra/${claimId}-topic-claim.yaml`,
        content: `apiVersion: messaging.shopscale.io/v1alpha1
kind: KafkaTopicClaim
metadata:
  name: ${serviceName}-${claimId}-topic
  namespace: default
spec:
  parameters:
    topicName: ${serviceName.toLowerCase()}-${claimId}
    partitions: ${params.partitions || 3}
    replicationFactor: ${params.replicationFactor || 2}
`
      };
    case 'ssl':
      return {
        file: `infra/${claimId}-cert-claim.yaml`,
        content: `apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${serviceName}-${claimId}-cert
  namespace: default
spec:
  secretName: ${serviceName}-${claimId}-tls-secret
  issuerRef:
    name: ${params.issuer || 'letsencrypt-prod'}
    kind: ClusterIssuer
  dnsNames:
    - ${params.domainName || serviceName.toLowerCase() + '.shopscale.io'}
`
      };
    case 'oauth':
      return {
        file: `infra/${claimId}-credentials-claim.yaml`,
        content: `apiVersion: security.shopscale.io/v1alpha1
kind: PaymentOAuthCredentialsClaim
metadata:
  name: ${serviceName}-${claimId}
  namespace: default
spec:
  parameters:
    provider: ${params.provider || 'Stripe'}
    scopes:
      - ${params.scopes || 'charges.read'}
  writeConnectionSecretToRef:
    name: ${secretName}
`
      };
    case 'grafana':
      return {
        file: `infra/${claimId}-dashboard-claim.yaml`,
        content: `apiVersion: observability.shopscale.io/v1alpha1
kind: GrafanaDashboardClaim
metadata:
  name: ${serviceName}-${claimId}
  namespace: default
spec:
  parameters:
    folder: ${params.folder || 'Platform-Microservices'}
    metrics:
      - ${params.metrics || 'http_requests_total'}
`
      };
    case 'slack':
      return {
        file: `infra/${claimId}-alerts-claim.yaml`,
        content: `apiVersion: notification.shopscale.io/v1alpha1
kind: SlackAlertWebhookClaim
metadata:
  name: ${serviceName}-${claimId}
  namespace: default
spec:
  parameters:
    channel: "${params.slackChannel || '#alerts-platform-prod'}"
    webhookUrl: "${params.slackWebhookUrl || 'https://slack.workspace.internal/webhook-endpoint'}"
    events:
      - ${params.alertEvents || 'PodCrashLoopBackOff'}
`
      };
    case 'domain':
      return {
        file: `infra/${claimId}-ingress-claim.yaml`,
        content: `apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${serviceName}-${claimId}-ingress
  namespace: default
spec:
  rules:
  - host: ${params.subdomainHost || 'api.' + serviceName.toLowerCase() + '.shopscale.com'}
    http:
      paths:
      - path: ${params.pathPrefix || '/'}
        pathType: Prefix
        backend:
          service:
            name: ${serviceName}
            port:
              number: 80
`
      };
    default:
      throw new Error(`Unknown claim type: ${claimType}`);
  }
}

module.exports = {
  generateClaimYaml
};
