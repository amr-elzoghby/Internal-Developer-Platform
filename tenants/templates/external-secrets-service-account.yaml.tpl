apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets-sa
  annotations:
    eks.amazonaws.com/role-arn: ${EXTERNAL_SECRETS_ROLE_ARN}
automountServiceAccountToken: false
