"""Nonsecret output, environment isolation and GitOps render regression tests."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[3]
PATH = ROOT / 'platform/operations/render-platform.py'
SPEC = importlib.util.spec_from_file_location('platform_render', PATH)
render = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(render)


def fixture():
    account = '851236938302'
    role = 'arn:aws:iam::' + account + ':role/'
    return {
        ('eks', 'platform_context'): {'aws_account_id': account, 'aws_region': 'us-east-1', 'cluster_name': 'idp-prod', 'environment': 'prod'},
        ('network', 'vpc_id'): 'vpc-0123456789abcdef0', ('eks', 'vpc_id'): 'vpc-0123456789abcdef0',
        ('network', 'private_subnet_ids'): ['subnet-0123456789abcdef0', 'subnet-0123456789abcdef1'],
        ('network', 'data_subnet_ids'): ['subnet-0123456789abcdef2', 'subnet-0123456789abcdef3'],
        ('network', 'public_subnet_ids'): ['subnet-0123456789abcdef4', 'subnet-0123456789abcdef5'],
        ('network', 'data_subnet_cidrs'): ['10.0.20.0/24', '10.0.21.0/24'],
        ('network', 'public_subnet_cidrs'): ['10.0.1.0/24', '10.0.2.0/24'],
        ('network', 'private_subnet_cidrs'): ['10.0.32.0/20', '10.0.48.0/20'],
        ('eks', 'node_security_group_id'): 'sg-0123456789abcdef0',
        ('eks', 'approved_server_ami_id'): 'ami-0123456789abcdef0',
        ('eks', 'ec2_instance_profile_name'): 'idp-prod-crossplane-server',
        ('eks', 'karpenter_node_role_name'): 'idp-prod-karpenter-nodes-role',
        ('eks', 'rds_monitoring_role_arn'): role + 'idp-prod-rds-monitoring',
        ('eks', 'crossplane_provider_role_arns'): {name: role + 'idp-prod-crossplane-' + name for name in ('s3', 'rds', 'elasticache', 'ec2')},
        ('eks', 'tenant_external_secrets_role_arns'): {name: role + name + '-eso' for name in render.TEAMS},
    }


class PlatformRenderTest(unittest.TestCase):
    def values(self, inputs=None):
        data = inputs or fixture()
        return render.load_values(lambda stack, name: data[(stack, name)])

    def test_actual_all_scope_templates_render_and_bundle_is_repeatable(self):
        values, roles = self.values()
        for scope in ['compositions', 'karpenter', 'network-policy', 'tenants', 'runtimes', 'gitops', 'bundle']:
            objects = render.render(scope, values, roles, 'identity-platform')
            self.assertTrue(objects)
            self.assertFalse(any(obj['kind'] == 'Secret' for obj in objects))
            self.assertNotIn('${', json.dumps(objects))
        bundle = render.render('bundle', values, roles)
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            render.write_bundle(bundle, directory)
            first = (directory / 'manifest.yaml').read_bytes()
            render.write_bundle(bundle, directory)
            self.assertEqual(first, (directory / 'manifest.yaml').read_bytes())
            self.assertEqual(yaml.safe_load((directory / 'kustomization.yaml').read_text())['resources'], ['manifest.yaml'])

    def test_admission_bindings_follow_typed_policy_wave(self):
        values, roles = self.values()
        objects = render.render('bundle', values, roles)
        policies = {x['metadata']['name']: x for x in objects if x['kind'] == 'ValidatingAdmissionPolicy'}
        bindings = [x for x in objects if x['kind'] == 'ValidatingAdmissionPolicyBinding']
        self.assertEqual(len(bindings), 3)
        for binding in bindings:
            policy = policies[binding['spec']['policyName']]
            self.assertLess(int(policy['metadata']['annotations']['argocd.argoproj.io/sync-wave']), int(binding['metadata']['annotations']['argocd.argoproj.io/sync-wave']))
            self.assertIn('Deny', binding['spec']['validationActions'])
        app = yaml.safe_load((ROOT / 'platform/gitops/argocd/platform-bootstrap.yaml').read_text())
        self.assertIn('PruneLast=true', app['spec']['syncPolicy']['syncOptions'])
        self.assertFalse(app['spec']['syncPolicy']['automated']['allowEmpty'])

    def test_every_bundle_resource_is_permitted_by_the_bootstrap_project(self):
        values, roles = self.values()
        project = yaml.safe_load((ROOT / 'platform/gitops/argocd/projects/platform-bootstrap.yaml').read_text())['spec']
        destinations = {item['namespace'] for item in project['destinations']}
        for obj in render.render('bundle', values, roles):
            group = obj['apiVersion'].rsplit('/', 1)[0] if '/' in obj['apiVersion'] else ''
            cluster_scoped = obj['kind'] in render.CLUSTER_KINDS
            field = 'clusterResourceWhitelist' if cluster_scoped else 'namespaceResourceWhitelist'
            with self.subTest(kind=obj['kind'], name=obj['metadata']['name']):
                self.assertIn({'group': group, 'kind': obj['kind']}, project[field])
                if not cluster_scoped:
                    self.assertIn(obj['metadata']['namespace'], destinations)

    def test_wrong_account_vpc_or_overlapping_networks_rejected(self):
        for key, value in [(('eks', 'vpc_id'), 'vpc-00000000000000000'),
                           (('network', 'data_subnet_cidrs'), ['0.0.0.0/0', '10.0.21.0/24']),
                           (('network', 'data_subnet_cidrs'), ['10.0.32.0/24', '10.0.21.0/24']),
                           (('eks', 'rds_monitoring_role_arn'), 'arn:aws:iam::111111111111:role/other')]:
            inputs = fixture()
            inputs[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.values(inputs)

    def test_output_allowlist_blocks_secret_and_malformed_names_before_subprocess(self):
        with patch.object(render.subprocess, 'check_output') as call:
            for name in ['db_password', '../secrets', 'crossplane_provider_role_arns;env']:
                with self.assertRaises(ValueError):
                    render.terraform_output('eks', name)
            call.assert_not_called()

    def test_backend_target_must_match_account_region_bucket_and_key(self):
        expected = {'environment': 'prod', 'aws_account_id': '851236938302'}
        config = {'bucket': 'amr-tf-state-2026-851236938302-us-east-1-an', 'region': 'us-east-1', 'key': 'prod/eks/terraform.tfstate', 'allowed_account_ids': ['851236938302']}
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {}, clear=True):
            directory = Path(tmp)
            path = directory / 'terraform.tfstate'
            path.write_text(json.dumps({'backend': {'type': 's3', 'config': config}}))
            render.verify_backend(directory, 'eks', expected)
            for key, value in [('key', 'other/eks/terraform.tfstate'), ('region', 'us-west-2'), ('allowed_account_ids', ['111111111111']), ('bucket', 'other-state')]:
                wrong = {**config, key: value}
                path.write_text(json.dumps({'backend': {'type': 's3', 'config': wrong}}))
                with self.subTest(key=key), self.assertRaises(ValueError):
                    render.verify_backend(directory, 'eks', expected)

    def test_invalid_bundle_does_not_touch_destination(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / 'not-created'
            with self.assertRaises(ValueError):
                render.write_bundle([{'apiVersion': 'v1', 'kind': 'Secret', 'metadata': {'name': 'forbidden'}}], target)
            self.assertFalse(target.exists())

    def test_tenant_bootstrap_uses_rendered_networks_and_environment(self):
        inputs = fixture()
        context = inputs[('eks', 'platform_context')]
        context.update(aws_account_id='123456789012', aws_region='eu-west-1', cluster_name='idp-sandbox', environment='sandbox')
        for key, value in inputs.items():
            if isinstance(value, str):
                inputs[key] = value.replace('851236938302', '123456789012')
            elif key[1].endswith('role_arns'):
                inputs[key] = {name: role.replace('851236938302', '123456789012') for name, role in value.items()}
        values, roles = self.values(inputs)
        objects = render.render('tenants', values, roles)
        self.assertEqual(sum(obj['kind'] == 'Namespace' for obj in objects), 3)
        for obj in objects:
            if obj['kind'] == 'Namespace':
                self.assertEqual(obj['metadata']['labels']['platform.idp.io/image-registry'], '123456789012.dkr.ecr.eu-west-1.amazonaws.com')
            if obj['kind'] == 'SecretStore':
                self.assertEqual(obj['spec']['provider']['aws']['region'], 'eu-west-1')
        self.assertNotIn('${', json.dumps(objects))

    def test_sandbox_cannot_use_production_identity(self):
        with patch.dict(os.environ, {'IDP_ENVIRONMENT': 'sandbox', 'IDP_AWS_ACCOUNT_ID': '851236938302',
                                     'IDP_AWS_REGION': 'us-east-1', 'IDP_CLUSTER_NAME': 'sandbox'}, clear=True):
            with self.assertRaises(ValueError):
                render.expected_identity()

    def test_sandbox_cannot_publish_production_gitops_configuration(self):
        values, roles = self.values()
        values['ENVIRONMENT'] = 'dev'
        for scope in ('bundle', 'gitops'):
            with self.subTest(scope=scope), self.assertRaisesRegex(ValueError, 'production-only'):
                render.render(scope, values, roles)
        self.assertTrue(render.render('tenants', values, roles))


if __name__ == '__main__':
    unittest.main()
