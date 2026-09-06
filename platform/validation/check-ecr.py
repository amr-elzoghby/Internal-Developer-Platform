#!/usr/bin/env python3
"""Read-only drift check for Terraform-owned registries before publishing."""
import json
import subprocess
import sys

repository = sys.argv[1]

def aws(*args):
    return json.loads(subprocess.check_output(['aws', 'ecr', *args, '--output', 'json'], text=True))

try:
    repo = aws('describe-repositories', '--repository-names', repository)['repositories'][0]
    assert repo['imageTagMutability'] == 'IMMUTABLE', 'tags must be immutable'
    assert repo['imageScanningConfiguration']['scanOnPush'] is True, 'scanOnPush required'
    assert repo['encryptionConfiguration']['encryptionType'] in ['AES256', 'KMS', 'KMS_DSSE'], 'encryption required'
    tags = {tag['Key']: tag['Value'] for tag in aws('list-tags-for-resource', '--resource-arn', repo['repositoryArn'])['tags']}
    assert tags.get('ManagedBy') == 'Terraform', 'repository must be in Terraform inventory'
    assert tags.get('Project') == 'internal-developer-platform', 'project owner tag mismatch'
    assert repository == 'idp-' + tags.get('Team', '') + '-' + tags.get('Service', ''), 'service owner tags mismatch'
    policy = json.loads(aws('get-lifecycle-policy', '--repository-name', repository)['lifecyclePolicyText'])
    assert policy['rules'], 'lifecycle policy required'
    for rule in policy['rules']:
        assert rule['selection']['tagStatus'] == 'untagged', 'tagged release/rollback images must never expire automatically'
    print('Terraform ECR baseline verified:', repository)
except (subprocess.CalledProcessError, AssertionError, KeyError, ValueError) as error:
    raise SystemExit(f'ECR baseline invalid or absent for {repository}: {error}. Provision/reconcile service_repositories through reviewed Terraform first.')
