#!/usr/bin/env python3
"""Render reviewed, nonsecret Terraform outputs into a deterministic platform bundle."""
import argparse
import hashlib
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

import yaml

ROOT = Path(__file__).resolve().parents[2]
TEAMS = ('identity-platform', 'platform-engineering', 'data-platform')
OUTPUTS = {
    'network': {'vpc_id', 'public_subnet_ids', 'private_subnet_ids', 'data_subnet_ids',
                'data_subnet_cidrs', 'private_subnet_cidrs', 'public_subnet_cidrs'},
    'eks': {'platform_context', 'cluster_name', 'cluster_endpoint', 'vpc_id',
            'node_security_group_id', 'crossplane_provider_role_arns',
            'tenant_external_secrets_role_arns', 'approved_server_ami_id',
            'ec2_instance_profile_name', 'rds_monitoring_role_arn',
            'karpenter_node_role_name', 'load_balancer_controller_role_arn',
            'service_repository_urls', 'github_actions_role_arn',
            'github_actions_read_role_arn'},
}
CLUSTER_KINDS = {'Namespace', 'ClusterRole', 'ClusterRoleBinding', 'StorageClass',
                 'CompositeResourceDefinition', 'Composition', 'DeploymentRuntimeConfig',
                 'Provider', 'Function', 'ManagedResourceActivationPolicy',
                 'ClusterProviderConfig', 'EC2NodeClass', 'NodePool',
                 'ValidatingAdmissionPolicy', 'ValidatingAdmissionPolicyBinding'}


def expected_identity():
    environment = os.environ.get('IDP_ENVIRONMENT', 'prod')
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,20}', environment):
        raise ValueError('Invalid IDP_ENVIRONMENT')
    defaults = {'aws_account_id': '851236938302', 'aws_region': 'us-east-1', 'cluster_name': 'idp-prod'}
    variables = {'aws_account_id': 'IDP_AWS_ACCOUNT_ID', 'aws_region': 'IDP_AWS_REGION', 'cluster_name': 'IDP_CLUSTER_NAME'}
    context = {'environment': environment}
    for key, variable in variables.items():
        if environment != 'prod' and not os.environ.get(variable):
            raise ValueError('Nonproduction output access requires ' + variable)
        context[key] = os.environ.get(variable, defaults[key])
        if environment == 'prod' and context[key] != defaults[key]:
            raise ValueError('Production identity is review-pinned')
    for key, pattern in {'aws_account_id': r'[0-9]{12}', 'aws_region': r'[a-z]{2}-[a-z]+-[0-9]+',
                         'cluster_name': r'[A-Za-z0-9][A-Za-z0-9_-]{0,99}'}.items():
        identifier(context[key], pattern, key)
    if environment != 'prod' and (context['aws_account_id'] == defaults['aws_account_id'] or context['cluster_name'] == defaults['cluster_name']):
        raise ValueError('A sandbox must use a separate account and cluster identity')
    return context


def verify_backend(data_dir, stack, expected):
    path = data_dir / 'terraform.tfstate'
    if not path.is_file():
        raise ValueError('Initialize this stack through the reviewed Terraform plan workflow first: ' + str(data_dir))
    backend = json.loads(path.read_text()).get('backend', {})
    config = backend.get('config', {})
    required = {
        'bucket': os.environ.get('IDP_BACKEND_BUCKET', 'amr-tf-state-2026-851236938302-us-east-1-an'),
        'region': os.environ.get('IDP_BACKEND_REGION', 'us-east-1'),
        'key': expected['environment'] + '/' + stack + '/terraform.tfstate',
        'allowed_account_ids': [expected['aws_account_id']],
    }
    if expected['environment'] == 'prod' and (required['bucket'], required['region']) != ('amr-tf-state-2026-851236938302-us-east-1-an', 'us-east-1'):
        raise ValueError('Production backend identity is review-pinned')
    if backend.get('type') != 's3' or any(config.get(key) != value for key, value in required.items()):
        raise ValueError('Initialized backend differs from the reviewed account, bucket, region or stack key')


def terraform_output(stack, name):
    if name not in OUTPUTS.get(stack, set()):
        raise ValueError('Output is not on the explicit nonsecret allowlist: ' + stack + '/' + name)
    expected = expected_identity()
    data_dir = Path(os.environ.get('TF_DATA_DIR', str(ROOT / '.idp/terraform' / expected['environment'] / stack))).resolve()
    verify_backend(data_dir, stack, expected)
    env = {key: value for key, value in os.environ.items() if not key.startswith('TF_CLI_ARGS')}
    env.update(TF_DATA_DIR=str(data_dir), TF_WORKSPACE='default', AWS_PAGER='')
    directory = ROOT / 'infrastructure/terraform/stacks/prod' / stack
    raw = subprocess.check_output(['terraform', '-chdir=' + str(directory), 'output', '-json', name], env=env, text=True)
    value = json.loads(raw)
    if name == 'platform_context' and value != expected:
        raise ValueError('Terraform platform_context differs from the reviewed target')
    return value


def identifier(value, pattern, label):
    if not isinstance(value, str) or not re.fullmatch(pattern, value):
        raise ValueError('Invalid ' + label)
    return value


def ids(values, prefix, minimum=2):
    if not isinstance(values, list) or len(values) < minimum or len(set(values)) != len(values):
        raise ValueError('At least two distinct ' + prefix + ' IDs are required')
    return [identifier(value, prefix + r'-[0-9a-f]{8,17}', prefix) for value in values]


def cidrs(values, minimum_prefix=24):
    if not isinstance(values, list) or len(values) < 2:
        raise ValueError('At least two reviewed CIDRs are required')
    networks = [ipaddress.ip_network(value, strict=True) for value in values]
    if any(net.version != 4 or not net.is_private or net.prefixlen < minimum_prefix or net.prefixlen > 28 for net in networks):
        raise ValueError('Expected private IPv4 CIDRs within the approved prefix bounds')
    if any(a.overlaps(b) for i, a in enumerate(networks) for b in networks[i + 1:]):
        raise ValueError('Subnet CIDRs must not overlap')
    return [str(net) for net in networks]


def load_values(reader=terraform_output):
    context = reader('eks', 'platform_context')
    identifier(context['aws_account_id'], r'[0-9]{12}', 'account')
    identifier(context['aws_region'], r'[a-z]{2}-[a-z]+-[0-9]+', 'region')
    identifier(context['environment'], r'[a-z][a-z0-9-]{0,20}', 'environment')
    identifier(context['cluster_name'], r'[A-Za-z0-9][A-Za-z0-9_-]{0,99}', 'cluster name')
    vpc = identifier(reader('network', 'vpc_id'), r'vpc-[0-9a-f]{8,17}', 'VPC')
    if reader('eks', 'vpc_id') != vpc:
        raise ValueError('Network and EKS states refer to different VPCs')
    private = ids(reader('network', 'private_subnet_ids'), 'subnet')
    data = ids(reader('network', 'data_subnet_ids'), 'subnet')
    public = ids(reader('network', 'public_subnet_ids'), 'subnet')
    if set(private) & set(data) or set(private) & set(public) or set(data) & set(public):
        raise ValueError('Public, workload and data subnet IDs must be disjoint')
    data_cidrs = cidrs(reader('network', 'data_subnet_cidrs'))
    public_cidrs = cidrs(reader('network', 'public_subnet_cidrs'))
    private_cidrs = cidrs(reader('network', 'private_subnet_cidrs'), 16)
    if any(ipaddress.ip_network(a).overlaps(ipaddress.ip_network(b)) for a in data_cidrs + public_cidrs for b in private_cidrs):
        raise ValueError('Data/public CIDRs cannot overlap workload Pod subnet CIDRs')
    if any(ipaddress.ip_network(a).overlaps(ipaddress.ip_network(b)) for a in data_cidrs for b in public_cidrs):
        raise ValueError('Data/public CIDRs cannot overlap')
    if not (len(private) == len(private_cidrs) and len(data) == len(data_cidrs) and len(public) == len(public_cidrs)):
        raise ValueError('Subnet ID/CIDR counts disagree')
    role_pattern = r'arn:aws:iam::' + context['aws_account_id'] + r':role/[A-Za-z0-9+=,.@_/-]+'
    providers = reader('eks', 'crossplane_provider_role_arns')
    if set(providers) != {'s3', 'rds', 'elasticache', 'ec2'}:
        raise ValueError('All four isolated Crossplane roles are required')
    tenant_roles = reader('eks', 'tenant_external_secrets_role_arns')
    if set(tenant_roles) != set(TEAMS):
        raise ValueError('SecretStore role mapping must cover exactly the approved tenants')
    values = {
        'AWS_REGION': context['aws_region'], 'AWS_ACCOUNT_ID': context['aws_account_id'],
        'ENVIRONMENT': context['environment'], 'CLUSTER_NAME': context['cluster_name'],
        'RESOURCE_NAME_PREFIX': 'idp-' + context['environment'], 'VPC_ID': vpc,
        'PRIVATE_SUBNET_1': private[0], 'PRIVATE_SUBNET_2': private[1],
        'DATA_SUBNET_1': data[0], 'DATA_SUBNET_2': data[1],
        'PRIVATE_SUBNET_SELECTORS': json.dumps([{'id': subnet} for subnet in private]),
        'DATA_SUBNET_PEERS': json.dumps([{'ipBlock': {'cidr': cidr}} for cidr in data_cidrs]),
        'PUBLIC_SUBNET_PEERS': json.dumps([{'ipBlock': {'cidr': cidr}} for cidr in public_cidrs]),
        'EKS_NODE_SECURITY_GROUP_ID': identifier(reader('eks', 'node_security_group_id'), r'sg-[0-9a-f]{8,17}', 'node security group'),
        'APPROVED_SERVER_AMI_ID': identifier(reader('eks', 'approved_server_ami_id'), r'ami-[0-9a-f]{8,17}', 'approved utility AMI'),
        'EC2_INSTANCE_PROFILE_NAME': identifier(reader('eks', 'ec2_instance_profile_name'), r'[A-Za-z0-9+=,.@_-]{1,128}', 'utility instance profile'),
        'KARPENTER_NODE_ROLE_NAME': identifier(reader('eks', 'karpenter_node_role_name'), r'[A-Za-z0-9+=,.@_-]{1,64}', 'Karpenter role'),
        'RDS_MONITORING_ROLE_ARN': identifier(reader('eks', 'rds_monitoring_role_arn'), role_pattern, 'RDS monitoring role'),
    }
    for provider, role in providers.items():
        values['CROSSPLANE_' + provider.upper() + '_ROLE_ARN'] = identifier(role, role_pattern, provider + ' role')
    for tenant, role in tenant_roles.items():
        identifier(role, role_pattern, tenant + ' SecretStore role')
    return values, tenant_roles


def render_file(path, values, namespace=None, wave=None):
    text = path.read_text()
    for key, value in values.items():
        text = text.replace('${' + key + '}', value)
    if re.search(r'\$\{[^}]+\}', text):
        raise ValueError('Unresolved render variable in ' + str(path))
    resources = [obj for obj in yaml.safe_load_all(text) if obj]
    for obj in resources:
        if namespace and obj['kind'] not in CLUSTER_KINDS:
            obj.setdefault('metadata', {})['namespace'] = namespace
        if wave is not None:
            obj.setdefault('metadata', {}).setdefault('annotations', {})['argocd.argoproj.io/sync-wave'] = str(wave)
    return resources


def admission_objects():
    path = ROOT / 'platform/security/admission/rollout.py'
    spec = importlib.util.spec_from_file_location('idp_admission_candidates', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    policies, bindings, _, _ = module.candidates()
    for policy in policies:
        policy['metadata'].setdefault('annotations', {})['argocd.argoproj.io/sync-wave'] = '-15'
    for binding in bindings:
        binding['metadata'].setdefault('annotations', {})['argocd.argoproj.io/sync-wave'] = '-14'
    return policies + bindings


def render(scope, values, tenant_roles, namespace=None):
    if scope in ('bundle', 'gitops') and values['ENVIRONMENT'] != 'prod':
        raise ValueError('The checked-in GitOps applications and bundle path are production-only; use direct bootstrap scopes for a sandbox')
    objects = []
    if scope in ('compositions', 'bundle'):
        for path in sorted((ROOT / 'infrastructure/crossplane/apis/compositions').glob('*.yaml')):
            objects += render_file(path, values, wave=-20)
    if scope in ('karpenter', 'bundle'):
        for filename, wave in [('node-class.yaml', -25), ('node-pool.yaml', -24)]:
            objects += render_file(ROOT / 'platform/bootstrap/karpenter' / filename, values, wave=wave)
    if scope == 'network-policy':
        if namespace not in TEAMS:
            raise ValueError('A reviewed tenant namespace is required')
        objects += render_file(ROOT / 'tenants/base/network-policy.yaml', values, namespace)
    if scope in ('tenants', 'bundle'):
        for team in TEAMS:
            namespace_objects = render_file(ROOT / 'tenants/namespaces' / (team + '.yaml'), values, wave=-60)
            namespace_objects[0]['metadata']['labels']['platform.idp.io/image-registry'] = values['AWS_ACCOUNT_ID'] + '.dkr.ecr.' + values['AWS_REGION'] + '.amazonaws.com'
            objects += namespace_objects
            for path in sorted((ROOT / 'tenants/base').glob('*.yaml')):
                baseline = render_file(path, values, team, -30)
                for obj in baseline:
                    if obj['kind'] == 'SecretStore':
                        obj['spec']['provider']['aws']['region'] = values['AWS_REGION']
                objects += baseline
            roles = {**values, 'EXTERNAL_SECRETS_ROLE_ARN': tenant_roles[team]}
            objects += render_file(ROOT / 'tenants/templates/external-secrets-service-account.yaml.tpl', roles, team, -35)
            objects += render_file(ROOT / 'tenants/rbac/bindings' / (team + '.yaml'), values, team, -35)
        objects += render_file(ROOT / 'tenants/rbac/cluster-roles.yaml', values, wave=-35)
    if scope in ('runtimes', 'bundle'):
        objects += render_file(ROOT / 'infrastructure/crossplane/packages/deployment-runtime-config.yaml', values, wave=-50)
    if scope == 'bundle':
        objects += render_file(ROOT / 'platform/bootstrap/storage/gp3.yaml', values, wave=-30)
        objects += render_file(ROOT / 'infrastructure/crossplane/packages/providers.yaml', values, wave=-45)
        objects += render_file(ROOT / 'infrastructure/crossplane/packages/managed-resource-activation-policy.yaml', values, wave=-45)
        for path in sorted((ROOT / 'infrastructure/crossplane/apis/definitions').glob('*.yaml')):
            objects += render_file(path, values, wave=-40)
        objects += render_file(ROOT / 'infrastructure/crossplane/provider-configs/provider-config.yaml', values, wave=-30)
        objects += admission_objects()
    if scope in ('gitops', 'bundle'):
        for path in sorted((ROOT / 'platform/gitops/argocd/projects').glob('*.yaml')):
            objects += render_file(path, values, 'argocd', 20)
        for path in sorted((ROOT / 'platform/gitops/argocd/applicationsets').glob('*.yaml')):
            objects += render_file(path, values, 'argocd', 30)
    validate_objects(objects)
    return objects


def validate_objects(objects):
    seen = set()
    for obj in objects:
        if obj.get('kind') == 'Secret':
            raise ValueError('Secret values must never enter the GitOps render bundle')
        if not all(isinstance(obj.get(key), str) and obj[key] for key in ('apiVersion', 'kind')):
            raise ValueError('Invalid manifest type')
        metadata = obj.get('metadata', {})
        if not metadata.get('name'):
            raise ValueError('Manifest name is required')
        if obj['kind'] not in CLUSTER_KINDS and not metadata.get('namespace'):
            raise ValueError('Namespaced manifest lacks an explicit namespace')
        key = (obj['apiVersion'], obj['kind'], metadata.get('namespace', ''), metadata['name'])
        if key in seen:
            raise ValueError('Duplicate rendered resource: ' + str(key))
        seen.add(key)
        if re.search(r'\$\{[^}]+\}', json.dumps(obj)):
            raise ValueError('Unresolved placeholder in rendered object')
        if obj['kind'] == 'Composition':
            compile(obj['spec']['pipeline'][0]['input']['script'], metadata['name'], 'exec')
        if obj['kind'] == 'NetworkPolicy':
            for direction, field in [('ingress', 'from'), ('egress', 'to')]:
                for rule in obj['spec'].get(direction, []):
                    if not isinstance(rule.get(field), list) or not rule[field]:
                        raise ValueError('Unrestricted or unrendered network peers')


def write_bundle(objects, directory):
    validate_objects(objects)
    encoded = yaml.safe_dump_all(objects, sort_keys=False)
    checksum = hashlib.sha256(encoded.encode()).hexdigest()
    content = '# Generated from reviewed nonsecret Terraform outputs. Review the entire Git diff before merging.\n# Manifest SHA256: ' + checksum + '\n' + encoded
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.render-', dir=directory) as temporary:
        staging = Path(temporary)
        (staging / 'manifest.yaml').write_text(content)
        (staging / 'kustomization.yaml').write_text('apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n  - manifest.yaml\n')
        os.replace(staging / 'manifest.yaml', directory / 'manifest.yaml')
        os.replace(staging / 'kustomization.yaml', directory / 'kustomization.yaml')
    print('Rendered reviewed bundle with ' + str(len(objects)) + ' objects; SHA256 ' + checksum, file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stack', choices=sorted(OUTPUTS))
    parser.add_argument('--name')
    parser.add_argument('--raw', action='store_true')
    parser.add_argument('--scope', choices=['compositions', 'network-policy', 'karpenter', 'tenants', 'runtimes', 'gitops', 'bundle'])
    parser.add_argument('--namespace')
    parser.add_argument('--output-dir', type=Path)
    args = parser.parse_args()
    if args.stack and args.name and not args.scope:
        value = terraform_output(args.stack, args.name)
        if args.raw:
            if not isinstance(value, str):
                parser.error('--raw is only valid for string outputs')
            print(value)
        else:
            print(json.dumps(value, sort_keys=True))
        return
    if not args.scope or args.stack or args.name or args.raw:
        parser.error('Choose either --scope or --stack NAME --name OUTPUT')
    if (args.scope == 'bundle') != bool(args.output_dir):
        parser.error('--output-dir is required only for bundle rendering')
    values, roles = load_values()
    objects = render(args.scope, values, roles, args.namespace)
    if args.scope == 'bundle':
        write_bundle(objects, args.output_dir)
    else:
        print(json.dumps({'apiVersion': 'v1', 'kind': 'List', 'items': objects}))


if __name__ == '__main__':
    main()
