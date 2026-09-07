#!/usr/bin/env python3
"""Render all composition branches and validate against checksum-pinned provider CRDs.

Requires PyYAML, jsonschema and protobuf. --download fetches only the locked public
schemas; otherwise validation is offline and fails if any schema is unavailable.
This does not replace live server-side CEL, admission, IAM and AWS reconciliation tests.
"""
import argparse
from collections import defaultdict
import copy
import hashlib
import json
from pathlib import Path
import re
import sys
from types import ModuleType, SimpleNamespace
import urllib.request

from google.protobuf.json_format import MessageToDict
from google.protobuf.struct_pb2 import Struct
import jsonschema
import yaml

ROOT = Path(__file__).resolve().parents[3]
LOCK = json.loads(Path(__file__).with_name('provider-schema-lock.json').read_text())
VALUES = {
    'VPC_ID': 'vpc-0123456789abcdef0',
    'PRIVATE_SUBNET_1': 'subnet-0123456789abcdef0',
    'PRIVATE_SUBNET_2': 'subnet-0123456789abcdef1',
    'DATA_SUBNET_1': 'subnet-0123456789abcdef2',
    'DATA_SUBNET_2': 'subnet-0123456789abcdef3',
    'AWS_REGION': 'us-east-1', 'ENVIRONMENT': 'prod',
    'RESOURCE_NAME_PREFIX': 'idp-prod',
    'EKS_NODE_SECURITY_GROUP_ID': 'sg-0123456789abcdef0',
    'APPROVED_SERVER_AMI_ID': 'ami-0123456789abcdef0',
    'EC2_INSTANCE_PROFILE_NAME': 'idp-prod-crossplane-server',
    'RDS_MONITORING_ROLE_ARN': 'arn:aws:iam::123456789012:role/idp-prod-rds-monitoring',
}


def strict_schema(schema):
    """Reject typos that an API server would otherwise prune from forProvider."""
    result = copy.deepcopy(schema)
    if result.get('type') == 'object' and 'properties' in result:
        result.setdefault('additionalProperties', False)
        result['properties'] = {key: strict_schema(value) for key, value in result['properties'].items()}
    if isinstance(result.get('items'), dict):
        result['items'] = strict_schema(result['items'])
    return result


def resource():
    return SimpleNamespace(resource=Struct(), ready=0)


def render(script, claim, ready_names=(), observed_resources=None):
    # Execute the exact embedded function against real protobuf Struct objects.
    # Only the SDK readiness constants are stubbed; no AWS or cluster is accessed.
    sdk_name = 'crossplane.function.proto.v1.run_function_pb2'
    for module in ['crossplane', 'crossplane.function', 'crossplane.function.proto', 'crossplane.function.proto.v1', sdk_name]:
        sys.modules.setdefault(module, ModuleType(module))
    sys.modules[sdk_name].READY_TRUE = 1
    sys.modules[sdk_name].READY_FALSE = 2
    observed = {}
    for name in ready_names:
        observed[name] = resource()
        observed[name].resource.update({'status': {'conditions': [{'type': 'Ready', 'status': 'True'}]}})
    for name, obj in (observed_resources or {}).items():
        observed.setdefault(name, resource()).resource.update(obj)
    xr = resource()
    xr.resource.update(claim)
    req = SimpleNamespace(observed=SimpleNamespace(composite=xr, resources=observed))
    rsp = SimpleNamespace(desired=SimpleNamespace(resources=defaultdict(resource)))
    namespace = {}
    exec(compile(script, '<composition>', 'exec'), namespace)
    namespace['compose'](req, rsp)
    return {name: (MessageToDict(item.resource), item.ready) for name, item in rsp.desired.resources.items()}


def check_database_names(template, claim):
    if claim['kind'] not in ('PostgresSQLInstance', 'RedisInstance'):
        return
    instance_key = 'rds-instance' if claim['kind'] == 'PostgresSQLInstance' else 'redis-instance'
    keys = ('subnet-group', instance_key)
    def cloud_name(key, obj):
        if key == 'rds-instance':
            assert 'crossplane.io/external-name' not in obj['metadata'].get('annotations', {})
            return obj['spec']['forProvider']['identifier']
        return obj['metadata']['annotations']['crossplane.io/external-name']
    for environment in ('prod', 'dev', 'staging'):
        script = template
        values = {**VALUES, 'ENVIRONMENT': environment, 'RESOURCE_NAME_PREFIX': 'idp-' + environment}
        for key, value in values.items():
            script = script.replace('${' + key + '}', value)
        first = render(script, claim)
        names = {key: cloud_name(key, first[key][0]) for key in keys}
        expected = 'idp-' + environment + '-crossplane-' + hashlib.sha256(claim['metadata']['uid'].encode()).hexdigest()[:16]
        assert all(name == expected and len(name) <= 40 for name in names.values())
        assert re.fullmatch(r'[a-z][a-z0-9-]*[a-z0-9]', expected) and '--' not in expected
        assert first[instance_key][0]['spec']['forProvider']['finalSnapshotIdentifier'] == expected + '-final'
        renamed = copy.deepcopy(claim)
        renamed['metadata']['name'] = 'a' * 63
        assert cloud_name(instance_key, render(script, renamed)[instance_key][0]) == expected
        replacement = copy.deepcopy(claim)
        replacement['metadata']['uid'] = 'fedcba98-7654-3210-fedc-ba9876543210'
        assert cloud_name(instance_key, render(script, replacement)[instance_key][0]) != expected
        observed = {key: first[key][0] for key in keys}
        if instance_key == 'rds-instance':
            observed[instance_key] = copy.deepcopy(observed[instance_key])
            observed[instance_key]['metadata']['annotations'] = {'crossplane.io/external-name': 'db-PROVIDERASSIGNEDID'}
        assert render(script, claim, observed_resources=observed) == first
        for key in keys:
            foreign = copy.deepcopy(observed)
            if key == 'rds-instance':
                foreign[key]['spec']['forProvider']['identifier'] = 'legacy-database'
            else:
                foreign[key]['metadata']['annotations']['crossplane.io/external-name'] = 'legacy-database'
            try:
                render(script, claim, observed_resources=foreign)
            except ValueError as error:
                assert 'reviewed naming migration' in str(error)
            else:
                raise AssertionError('Existing cloud identity was silently retargeted')


def check_security(kind, resources):
    objects = [item[0] for item in resources.values()]
    for obj in objects:
        assert 'Delete' not in obj['spec']['managementPolicies'], 'implicit cloud deletion enabled'
        fp = obj['spec']['forProvider']
        if 'tags' in fp:
            assert fp['tags']['Owner'] == 'identity-platform'
            assert fp['tags']['ExpiresOn'] == '2026-12-31'
        assert fp.get('cidrBlocks') != ['10.0.0.0/16'], 'VPC-wide ingress returned'
    by_kind = {obj['kind']: obj['spec']['forProvider'] for obj in objects}
    if kind == 'RedisInstance':
        p = by_kind['ReplicationGroup']
        assert p['transitEncryptionEnabled'] and p['transitEncryptionMode'] == 'required'
        assert p['atRestEncryptionEnabled'] == 'true' and p['autoGenerateAuthToken']
        assert p['numCacheClusters'] == 2 and p['multiAzEnabled'] and p['automaticFailoverEnabled']
        assert p['snapshotRetentionLimit'] >= 7
        assert by_kind['SecurityGroupRule']['sourceSecurityGroupId'] == VALUES['EKS_NODE_SECURITY_GROUP_ID']
    elif kind == 'PostgresSQLInstance':
        p = by_kind['Instance']
        assert p['multiAz'] and p['storageEncrypted'] and p['deletionProtection']
        assert not p['skipFinalSnapshot'] and not p['publiclyAccessible']
        assert p['monitoringInterval'] == 60 and p['backupRetentionPeriod'] >= 7
        assert by_kind['SecurityGroupRule']['sourceSecurityGroupId'] == VALUES['EKS_NODE_SECURITY_GROUP_ID']
    elif kind == 'ObjectBucket':
        assert len(objects) == 7
        assert by_kind['BucketVersioning']['versioningConfiguration']['status'] == 'Enabled'
        assert by_kind['BucketOwnershipControls']['rule']['objectOwnership'] == 'BucketOwnerEnforced'
        assert not by_kind['Bucket']['forceDestroy']
        assert all(by_kind['BucketPublicAccessBlock'][x] for x in ['blockPublicAcls', 'blockPublicPolicy', 'ignorePublicAcls', 'restrictPublicBuckets'])
        statement = json.loads(by_kind['BucketPolicy']['policy'])['Statement'][0]
        assert statement['Effect'] == 'Deny' and statement['Condition']['Bool']['aws:SecureTransport'] == 'false'
    elif kind == 'ServerInstance':
        p = by_kind['Instance']
        assert p['ami'] == VALUES['APPROVED_SERVER_AMI_ID']
        assert p['metadataOptions']['httpTokens'] == 'required'
        assert p['rootBlockDevice']['encrypted'] and not p['associatePublicIpAddress']
        assert p['iamInstanceProfile'] == VALUES['EC2_INSTANCE_PROFILE_NAME']
        assert by_kind['SecurityGroupRule']['type'] == 'egress'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--schema-dir', type=Path, default=Path('/tmp/idp-provider-schema-cache'))
    parser.add_argument('--download', action='store_true')
    args = parser.parse_args()
    args.schema_dir.mkdir(parents=True, exist_ok=True)
    schemas = {}
    for entry in LOCK['schemas']:
        target = args.schema_dir / entry['filename']
        if not target.exists() and args.download:
            with urllib.request.urlopen(entry['url'], timeout=30) as response:
                target.write_bytes(response.read())
        data = target.read_bytes()
        assert hashlib.sha256(data).hexdigest() == entry['sha256'], 'schema checksum mismatch: ' + str(target)
        crd = yaml.safe_load(data)
        for version in crd['spec']['versions']:
            schemas[(entry['group'] + '/' + version['name'], entry['kind'])] = strict_schema(version['schema']['openAPIV3Schema'])
    packages = list(yaml.safe_load_all((ROOT / 'infrastructure/crossplane/packages/providers.yaml').read_text()))
    for package in packages:
        if package['kind'] == 'Provider':
            assert package['spec']['package'].endswith(':' + LOCK['providerVersion']), 'provider/schema pin drift'
    activation = yaml.safe_load((ROOT / 'infrastructure/crossplane/packages/managed-resource-activation-policy.yaml').read_text())
    activated = set(activation['spec']['activate'])
    assert all(entry['filename'].split('_', 1)[1][:-5] + '.' + entry['group'] in activated for entry in LOCK['schemas']), 'required provider API is not activated'
    count = 0
    for path in sorted((ROOT / 'infrastructure/crossplane/apis/compositions').glob('*.yaml')):
        definition = yaml.safe_load(path.read_text())
        script = definition['spec']['pipeline'][0]['input']['script']
        for key, value in VALUES.items():
            script = script.replace('${' + key + '}', value)
        assert not re.search(r'\$\{[A-Z_0-9]+\}', script), 'unbound bootstrap variable in ' + str(path)
        kind = definition['spec']['compositeTypeRef']['kind']
        for size in ['small', 'medium']:
            claim = {'apiVersion': 'idp.io/v1alpha1', 'kind': kind,
                     'metadata': {'name': 'test-resource', 'namespace': 'identity-platform', 'uid': '01234567-89ab-cdef-0123-456789abcdef'},
                     'spec': {'size': size, 'owner': 'identity-platform', 'expiresOn': '2026-12-31', 'storageGB': 20, 'region': 'us-east-1', 'image': 'al2023-ssm'}}
            rendered = render(script, claim)
            for name, (obj, readiness) in rendered.items():
                jsonschema.Draft7Validator(schemas[(obj['apiVersion'], obj['kind'])]).validate(obj)
                assert readiness == 2, 'new resources cannot be ready before observation'
                count += 1
            check_security(kind, rendered)
            check_database_names(definition['spec']['pipeline'][0]['input']['script'], claim)
            assert all(item[1] == 1 for item in render(script, claim, rendered).values())
            partial = render(script, claim, list(rendered)[:-1])
            assert partial[list(rendered)[-1]][1] == 2, 'missing dependent resource masked as ready'
        print(path.name + ': both tiers, provider schemas, security and readiness passed')
    print(str(count) + ' rendered managed resources validated; live CEL/IAM/AWS checks remain required')


if __name__ == '__main__':
    main()
