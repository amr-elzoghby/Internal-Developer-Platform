const SUPPORTED_CLAIM_TYPES = Object.freeze(['postgres', 'redis', 's3', 'ec2']);

function toDnsLabel(value, fieldName) {
  const normalized = String(value || '')
    .toLowerCase()
    .replace(/[^a-z0-9-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 63)
    .replace(/-+$/g, '');

  if (!normalized) {
    throw new Error(`${fieldName} must contain at least one DNS-safe character`);
  }
  return normalized;
}

function approvedSize(value) {
  const size = value || 'small';
  if (!['small', 'medium'].includes(size)) {
    throw new Error('size must be one of: small, medium');
  }
  return size;
}

function boundedInteger(value, fallback, minimum, maximum, fieldName) {
  const parsed = Number(value ?? fallback);
  if (!Number.isInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw new Error(`${fieldName} must be an integer from ${minimum} to ${maximum}`);
  }
  return parsed;
}

function baseManifest(kind, name, namespace) {
  return `apiVersion: idp.io/v1alpha1
kind: ${kind}
metadata:
  name: ${name}
  namespace: ${namespace}
  annotations:
    argocd.argoproj.io/sync-options: Prune=false,Delete=false
`;
}

function generateClaimYaml(serviceName, claimType, params = {}) {
  if (!SUPPORTED_CLAIM_TYPES.includes(claimType)) {
    throw new Error(`Unsupported claim type: ${claimType}`);
  }

  const serviceId = toDnsLabel(serviceName, 'serviceName');
  const claimId = toDnsLabel(params.customClaimName || claimType, 'customClaimName');
  const namespace = toDnsLabel(params.namespace, 'namespace');
  const resourceName = toDnsLabel(`${serviceId}-${claimId}`, 'resourceName');
  const file = `infra/${claimId}-claim.yaml`;
  const size = approvedSize(params.size);

  switch (claimType) {
    case 'postgres': {
      const storageGB = boundedInteger(params.storageGB, 20, 20, 1000, 'storageGB');
      return {
        file,
        content: `${baseManifest('PostgresSQLInstance', resourceName, namespace)}spec:
  storageGB: ${storageGB}
  size: ${size}
`
      };
    }
    case 'redis':
      return {
        file,
        content: `${baseManifest('RedisInstance', resourceName, namespace)}spec:
  size: ${size}
`
      };
    case 's3':
      return {
        file,
        content: `${baseManifest('ObjectBucket', resourceName, namespace)}spec:
  region: us-east-1
`
      };
    case 'ec2': {
      const ami = String(params.approvedEc2AmiId || '');
      if (!/^ami-([0-9a-f]{8}|[0-9a-f]{17})$/.test(ami)) {
        throw new Error('APPROVED_EC2_AMI_ID must contain a reviewed AMI for us-east-1');
      }
      return {
        file,
        content: `${baseManifest('ServerInstance', resourceName, namespace)}spec:
  size: ${size}
  ami: ${ami}
`
      };
    }
    default:
      throw new Error(`Unsupported claim type: ${claimType}`);
  }
}

module.exports = {
  SUPPORTED_CLAIM_TYPES,
  generateClaimYaml
};
