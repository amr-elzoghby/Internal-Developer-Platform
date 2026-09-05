#!/usr/bin/env python3
"""Read-only AWS-tag inventory, including resources whose Kubernetes objects are lost."""
import argparse
import datetime
import json
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--region', required=True)
parser.add_argument('--environment', required=True)
args = parser.parse_args()
command = ['aws', 'resourcegroupstaggingapi', 'get-resources', '--region', args.region,
           '--tag-filters', 'Key=ManagedBy,Values=Crossplane-IDP',
           'Key=Environment,Values=' + args.environment, '--output', 'json']
# AWS CLI paginates all results; propagate failures instead of reporting an empty inventory.
resources = json.loads(subprocess.check_output(command))['ResourceTagMappingList']
today = datetime.date.today().isoformat()
rows = []
for resource in resources:
    tags = {tag['Key']: tag['Value'] for tag in resource['Tags']}
    expires = tags.get('ExpiresOn', '')
    rows.append({'arn': resource['ResourceARN'], 'namespace': tags.get('TenantNamespace'),
                 'claim': tags.get('ClaimName'), 'owner': tags.get('Owner'),
                 'expiresOn': expires or None,
                 'reviewRequired': not expires or expires < today})
print(json.dumps({'region': args.region, 'environment': args.environment,
                  'resources': sorted(rows, key=lambda row: row['arn'])}, indent=2))
