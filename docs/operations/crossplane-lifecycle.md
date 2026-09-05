# Crossplane ownership and retained resources

The four infrastructure APIs retain AWS resources: `managementPolicies` omit `Delete`, claims disable Argo prune/delete, and the claims ApplicationSet preserves resources. Every request names its owning tenant and an ownership review date. AWS tags preserve `ManagedBy`, `Environment`, `TenantNamespace`, `ClaimName`, `Owner`, and `ExpiresOn` outside the cluster. Expiry is an inventory review trigger; it does not authorize deleting data.

Run the read-only inventory weekly and before removing a claim, cluster, or VPC:

```bash
python3 infrastructure/crossplane/scripts/inventory.py --region us-east-1 --environment prod > inventory.json
kubectl get managed -A -o json > managed-resources.json
kubectl get objectbuckets,serverinstances,postgressqlinstances,redisinstances -A -o yaml > requests.yaml
```

Keep these files encrypted in the operator's restricted backup store; never commit connection Secrets. The AWS tagging API inventories taggable resources, not every subordinate configuration: supplement it with `describe-db-instances`, `describe-replication-groups`, `describe-instances`, `describe-security-groups`, and S3 bucket configuration checks for the recorded IDs. Inventory failures must block infrastructure teardown. The platform does not automatically create this operational backup store.

## Decommission checklist

1. Open a reviewed change identifying AWS account, region, claim UID, resource ARNs, owner approval, dependency inventory, recovery location, and retention deadline. Suspend clients and their writers. Record the current CompositionRevision and exported objects.
2. For RDS, create and wait for a manual final snapshot, record its ARN and encryption key, and test restoration to a separate instance. For Redis, create a final snapshot and verify restoration. For S3, preserve required object versions in the approved independent backup location before deleting any versions. For EC2, snapshot any required EBS data and record its restore procedure; utility instances must not hold unique application data.
3. Remove the claim from Git after export. `Prune=false` leaves it in Kubernetes. Explicitly pause reconciliation on the claim and its managed resources (`crossplane.io/paused: "true"`) during the change. Verify that automatic reconciliation has stopped before cloud changes.
4. An operator with the separately controlled deletion role removes resources through the AWS API only after the recovery test. Disable RDS deletion protection immediately before its approved deletion and require a unique final snapshot ID. Delete dependent instances/groups before subnet groups and security groups. A nonempty bucket requires an explicit object-version deletion decision; `forceDestroy` is never enabled by the platform.
5. Verify all approved ARNs are absent, retained backups exist, and no ENIs reference the groups/subnets. Explicitly remove retained Kubernetes objects using their existing no-Delete management policies, then remove unused ESO objects only after no workloads consume them. Do not remove finalizers to bypass a failing dependency.

Deleting a namespace, provider, cluster, or Terraform VPC is never the resource decommission workflow. `kubectl delete` with the default policies does not delete the AWS resource.

## Recovery and import

If the cluster is lost, restore package pins, XRDs, the exact CompositionRevision, tenant boundaries and SecretStores first. Restore only reviewed claim YAML with its recorded UID/name mapping; a recreated claim UID can otherwise name a new bucket. Recreate each managed resource using its recorded `crossplane.io/external-name`, tenant namespace, and `managementPolicies: [Observe]`. Validate that observed ARN/account/region, owner and settings match the inventory before adding `Update` and other policies. Do not enable `Create` until adoption is proven. Rebind recovered resources to the restored composition only after verifying ownership references and resource names in a sandbox drill.

No resources currently exist for this project. The first installation must run create → remove Git → retained inventory → restore → approved decommission drills for each API before production acceptance. Static checks cannot establish recovery times or IAM/API behavior.

References: [Crossplane management policies](https://docs.crossplane.io/latest/managed-resources/managed-resources/), [AWS tagging inventory](https://docs.aws.amazon.com/cli/latest/reference/resourcegroupstaggingapi/get-resources.html).
