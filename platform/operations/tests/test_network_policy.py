"""Exercise strict CNI rollout and its tenant gate using local command doubles."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import yaml

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('network_policy', ROOT / 'platform/operations/network-policy.py')
network = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(network)
CONTEXT = {'aws_account_id': '123456789012', 'aws_region': 'eu-west-1', 'cluster_name': 'idp-staging'}


def daemonset():
    return {'metadata': {'generation': 3}, 'spec': {'template': {'spec': {'containers': [
        {'name': 'aws-node', 'env': [{'name': 'NETWORK_POLICY_ENFORCING_MODE', 'value': 'strict'}]},
        {'name': 'aws-eks-nodeagent', 'args': ['--enable-network-policy=true']},
    ]}}}, 'status': {'observedGeneration': 3, 'desiredNumberScheduled': 2,
                    'updatedNumberScheduled': 2, 'numberReady': 2, 'numberAvailable': 2}}


class ClusterCommands:
    """Reject unexpected commands instead of allowing any AWS/Kubernetes access."""
    def __init__(self, configuration=None):
        self.observed = {'status': 'ACTIVE', 'configurationValues': json.dumps(configuration or {}),
                         'addonVersion': 'v1.22.4-eksbuild.3', 'serviceAccountRoleArn': 'existing-irsa-role'}
        self.daemonset = daemonset()
        self.policies = {obj['metadata']['namespace']: obj for obj in network.platform_objects()
                         if obj['kind'] == 'NetworkPolicy'}
        self.calls = []
        self.fail = lambda command: False
        self.update_status = 'Successful'

    def __call__(self, *command, payload=None):
        self.calls.append((command, payload))
        if self.fail(command):
            raise subprocess.CalledProcessError(23, command)
        if command[:3] == ('aws', 'eks', 'describe-addon'):
            return json.dumps({'addon': self.observed})
        if command[:3] == ('aws', 'eks', 'update-addon'):
            self.observed['configurationValues'] = command[command.index('--configuration-values') + 1]
            return json.dumps({'update': {'id': 'local-update'}})
        if command[:3] == ('aws', 'eks', 'describe-update'):
            return json.dumps({'update': {'status': self.update_status}})
        if command[:4] == ('aws', 'eks', 'wait', 'addon-active'):
            return ''
        if command[:2] == ('kubectl', 'apply'):
            objects = json.loads(payload)['items']
            self.policies = {obj['metadata']['namespace']: obj for obj in objects if obj['kind'] == 'NetworkPolicy'}
            return ''
        if command[:3] == ('kubectl', 'rollout', 'status'):
            return ''
        if command[:3] == ('kubectl', 'get', 'daemonset/aws-node'):
            return json.dumps(self.daemonset)
        if command[:3] == ('kubectl', 'get', 'networkpolicy/' + network.POLICY_NAME):
            return json.dumps(self.policies[command[command.index('-n') + 1]])
        raise AssertionError('Unexpected command: ' + repr(command))


class NetworkPolicyTest(unittest.TestCase):
    def install(self, commands):
        with patch.object(network, 'run', commands), contextlib.redirect_stdout(io.StringIO()):
            network.install(CONTEXT)

    def test_platform_connectivity_excludes_tenants_and_preserves_argo_ingress(self):
        objects = network.platform_objects()
        policies = [obj for obj in objects if obj['kind'] == 'NetworkPolicy']
        expected = {'kube-system', 'crossplane-system', 'argocd', 'external-secrets', 'reloader', 'monitoring'}
        self.assertEqual({obj['metadata']['namespace'] for obj in policies}, expected)
        self.assertEqual({obj['metadata']['name'] for obj in objects if obj['kind'] == 'Namespace'}, expected)
        for policy in policies:
            self.assertEqual(policy['spec']['podSelector'], {})
            self.assertEqual(policy['spec']['egress'], [{'to': [{'ipBlock': {'cidr': '0.0.0.0/0'}}]}])
            if policy['metadata']['namespace'] == 'argocd':
                self.assertNotIn('Ingress', policy['spec']['policyTypes'])
                self.assertNotIn('ingress', policy['spec'])
            else:
                self.assertEqual(policy['spec']['ingress'], [{'from': [{'ipBlock': {'cidr': '0.0.0.0/0'}}]}])
        chart = yaml.safe_load((ROOT / 'platform/gitops/argocd/install/values.yaml').read_text())
        argo = [obj for obj in policies + chart['extraObjects']
                if obj['kind'] == 'NetworkPolicy' and obj['metadata']['namespace'] == 'argocd']
        ingress_rules = [rule for obj in argo for rule in obj['spec'].get('ingress', [])]
        self.assertTrue(ingress_rules)
        for rule in ingress_rules:
            self.assertTrue(rule.get('from'), 'An unrestricted ingress rule would override Argo isolation')
            for peer in rule['from']:
                self.assertTrue(peer.get('podSelector', {}).get('matchLabels') or
                                peer.get('namespaceSelector', {}).get('matchLabels'))

    def test_failed_policy_apply_cannot_enable_strict_mode(self):
        commands = ClusterCommands()
        commands.fail = lambda command: command[:2] == ('kubectl', 'apply')
        with self.assertRaises(subprocess.CalledProcessError):
            self.install(commands)
        self.assertEqual([command[:3] for command, _ in commands.calls], [
            ('aws', 'eks', 'describe-addon'), ('kubectl', 'apply', '--server-side')])

    def test_install_preserves_config_version_and_irsa_and_uses_reviewed_context(self):
        original = {'enableNetworkPolicy': 'false', 'env': {'WARM_ENI_TARGET': '1'},
                    'nodeAgent': {'metricsBindAddr': '8162'}}
        snapshot = copy.deepcopy(original)
        commands = ClusterCommands(original)
        self.install(commands)
        self.assertEqual(original, snapshot)
        self.assertEqual(json.loads(commands.observed['configurationValues']), {
            **original, 'enableNetworkPolicy': 'true',
            'env': {**original['env'], 'NETWORK_POLICY_ENFORCING_MODE': 'strict'}})
        calls = [command for command, _ in commands.calls]
        update = next(command for command in calls if command[:3] == ('aws', 'eks', 'update-addon'))
        self.assertNotIn('--addon-version', update)
        self.assertNotIn('--service-account-role-arn', update)
        self.assertLess(next(i for i, command in enumerate(calls) if command[:2] == ('kubectl', 'apply')), calls.index(update))
        for command in calls:
            if command[0] == 'aws':
                self.assertEqual(command[command.index('--region') + 1], CONTEXT['aws_region'])
                identity = '--name' if '--name' in command else '--cluster-name'
                self.assertEqual(command[command.index(identity) + 1], CONTEXT['cluster_name'])

    def test_already_strict_install_is_idempotent_but_still_checks_rollout(self):
        commands = ClusterCommands(network.strict_configuration({'env': {'WARM_ENI_TARGET': '1'}}))
        self.install(commands)
        self.install(commands)
        calls = [command for command, _ in commands.calls]
        self.assertFalse(any(command[:3] == ('aws', 'eks', 'update-addon') for command in calls))
        self.assertEqual(sum(command[:3] == ('kubectl', 'rollout', 'status') for command in calls), 4)

    def test_config_and_actual_daemonset_must_both_be_strict_and_fully_rolled_out(self):
        observed = ClusterCommands(network.strict_configuration({})).observed
        network.verify_configuration(observed, daemonset())
        mutations = [
            lambda addon, ds: addon.update(status='UPDATING'),
            lambda addon, ds: addon.update(configurationValues='{}'),
            lambda addon, ds: addon.update(configurationValues=json.dumps({'enableNetworkPolicy': 'false', 'env': {'NETWORK_POLICY_ENFORCING_MODE': 'strict'}})),
            lambda addon, ds: ds['spec']['template']['spec']['containers'][0]['env'][0].update(value='standard'),
            lambda addon, ds: ds['spec']['template']['spec']['containers'].pop(),
            lambda addon, ds: ds['spec']['template']['spec']['containers'][1].update(args=['--enable-network-policy=false']),
            lambda addon, ds: ds['status'].update(observedGeneration=2),
            lambda addon, ds: ds['status'].update(desiredNumberScheduled=0),
        ] + [lambda addon, ds, field=field: ds['status'].update({field: 1})
             for field in ('updatedNumberScheduled', 'numberReady', 'numberAvailable')]
        for index, mutate in enumerate(mutations):
            addon, ds = copy.deepcopy(observed), daemonset()
            mutate(addon, ds)
            with self.subTest(index=index), self.assertRaises(ValueError):
                network.verify_configuration(addon, ds)

    def test_update_or_rollout_failure_never_reports_success(self):
        for failure in ('Failed', 'Cancelled', 'daemonset/aws-node', 'deployment/coredns'):
            commands = ClusterCommands()
            if failure in ('Failed', 'Cancelled'):
                commands.update_status = failure
            else:
                commands.fail = lambda command: command[:4] == ('kubectl', 'rollout', 'status', failure)
            with self.subTest(failure=failure), self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
                self.install(commands)
            self.assertFalse(any(command[:3] == ('kubectl', 'get', 'daemonset/aws-node') for command, _ in commands.calls))

    def test_in_progress_addon_blocks_mutation_and_update_timeout_fails_closed(self):
        commands = ClusterCommands()
        commands.observed['status'] = 'UPDATING'
        with self.assertRaises(ValueError):
            self.install(commands)
        self.assertEqual(len(commands.calls), 1)
        with patch.object(network.time, 'monotonic', side_effect=[0, 601]), self.assertRaises(TimeoutError):
            network.wait_update(CONTEXT, 'local-update')

    def test_check_is_read_only_and_rejects_connectivity_policy_drift(self):
        commands = ClusterCommands(network.strict_configuration({}))
        with patch.object(network, 'run', commands):
            network.check(CONTEXT)
            commands.policies['argocd']['spec']['ingress'] = [{}]
            with self.assertRaisesRegex(ValueError, 'policy drift'):
                network.check(CONTEXT)
        self.assertTrue(all(command[:3] == ('aws', 'eks', 'describe-addon') or
                            command[:2] == ('kubectl', 'get') for command, _ in commands.calls))

    def test_actions_require_the_guarded_snapshot_and_use_reviewed_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            snapshot = Path(directory) / 'snapshot'
            snapshot.touch()
            environments = [{}, {'KUBECONFIG': str(snapshot)},
                            {'KUBECONFIG': 'different', 'IDP_VERIFIED_KUBECONFIG': str(snapshot)},
                            {'KUBECONFIG': '/missing', 'IDP_VERIFIED_KUBECONFIG': '/missing'}]
            for environment in environments:
                with patch.dict(os.environ, environment, clear=True), patch('sys.argv', ['network-policy.py', 'check']), \
                        patch.object(network, 'run') as run, contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    network.main()
                run.assert_not_called()
            for action in ('install', 'check'):
                verified = SimpleNamespace(read_environment=Mock(return_value=CONTEXT))
                spec = SimpleNamespace(loader=SimpleNamespace(exec_module=Mock()))
                with patch.dict(os.environ, {'KUBECONFIG': str(snapshot), 'IDP_VERIFIED_KUBECONFIG': str(snapshot),
                                             'CLUSTER_NAME': 'untrusted-override'}, clear=True), \
                        patch('sys.argv', ['network-policy.py', action]), \
                        patch.object(network.importlib.util, 'spec_from_file_location', return_value=spec), \
                        patch.object(network.importlib.util, 'module_from_spec', return_value=verified), \
                        patch.object(network, action) as execute:
                    network.main()
                verified.read_environment.assert_called_once_with()
                execute.assert_called_once_with(CONTEXT)

    def test_render_is_offline_and_does_not_require_cluster_credentials(self):
        output = io.StringIO()
        with patch.dict(os.environ, {}, clear=True), patch('sys.argv', ['network-policy.py', 'render']), \
                patch.object(network, 'run') as run, contextlib.redirect_stdout(output):
            network.main()
        self.assertEqual(json.loads(output.getvalue())['items'], network.platform_objects())
        run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
