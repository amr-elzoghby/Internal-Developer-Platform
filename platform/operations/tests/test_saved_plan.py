import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

path = Path(__file__).resolve().parents[1] / "terraform-plan.py"
spec = importlib.util.spec_from_file_location("saved_plan", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SavedPlanTest(unittest.TestCase):
    def test_review_binds_exact_plan_and_source(self):
        with tempfile.TemporaryDirectory() as directory:
            plan = Path(directory) / "plan"
            plan.write_bytes(b"reviewed plan")
            sha = module.digest(plan)
            metadata = {"sha256": sha, "source_sha256": "source"}
            module.verify_review(plan, metadata, sha, "source")
            with self.assertRaises(ValueError):
                module.verify_review(plan, metadata, "", "source")
            with self.assertRaises(ValueError):
                module.verify_review(plan, metadata, sha, "changed source")
            plan.write_bytes(b"different plan")
            with self.assertRaises(ValueError):
                module.verify_review(plan, metadata, sha, "source")

    def test_environment_cannot_inject_destroy_or_skip_locks(self):
        with patch.dict(module.os.environ, {"TF_CLI_ARGS": "-lock=false", "TF_CLI_ARGS_plan": "-destroy", "AWS_PROFILE": "reviewed"}, clear=True):
            self.assertEqual(module.safe_environment(), {"AWS_PROFILE": "reviewed"})

    def test_wrong_backend_key_or_type_is_rejected(self):
        expected = {"bucket": "reviewed", "key": "prod/eks/terraform.tfstate", "region": "us-east-1"}
        actual = {"backend": {"type": "s3", "config": expected.copy()}}
        module.verify_backend(actual, expected)
        actual["backend"]["config"]["key"] = "sandbox/eks/terraform.tfstate"
        with self.assertRaises(ValueError):
            module.verify_backend(actual, expected)
        actual["backend"]["type"] = "local"
        with self.assertRaises(ValueError):
            module.verify_backend(actual, expected)


class SavedPlanWorkflowTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / 'infrastructure/terraform/stacks/prod/network/main.tf'
        self.source.parent.mkdir(parents=True)
        self.source.write_text('# reviewed source\n')
        self.state = {'lineage': 'reviewed-lineage', 'serial': 7}
        self.inventory = {'ResourceTagMappingList': []}
        self.calls = []
        self.approval = ''
        self.account = module.PROD_ACCOUNT

    def invoke(self, action, destroy=False, stack='network'):
        args = ['terraform-plan.py', action, '--stack', stack] + (['--destroy'] if destroy else [])
        env = {'CONFIRM_DESTROY': '851236938302/us-east-1/idp-prod', 'APPROVE_PLAN_SHA256': self.approval,
               'TF_CLI_ARGS_plan': '-destroy -lock=false'}
        original_mask = os.umask(0o077)
        try:
            with patch.object(module, 'ROOT', self.root), patch('sys.argv', args), patch.dict(os.environ, env, clear=True), \
                 patch.object(module.subprocess, 'check_output', side_effect=self.read), \
                 patch.object(module.subprocess, 'run', side_effect=self.run_command):
                module.main()
        finally:
            os.umask(original_mask)

    def read(self, command, **kwargs):
        self.calls.append(command)
        if command[1:3] == ['sts', 'get-caller-identity']:
            return self.account + '\n'
        if command[1] == 'resourcegroupstaggingapi':
            return json.dumps(self.inventory)
        if command[2:] == ['state', 'pull']:
            return json.dumps(self.state)
        self.fail('Unexpected external read: ' + str(command))

    def run_command(self, command, **kwargs):
        self.calls.append(command)
        self.assertNotIn('TF_CLI_ARGS_plan', kwargs['env'])
        self.assertEqual(kwargs['env']['TF_WORKSPACE'], 'default')
        action = command[2]
        if action == 'init':
            config = {}
            for arg in command:
                if arg.startswith('-backend-config='):
                    key, value = arg[len('-backend-config='):].split('=', 1)
                    try:
                        value = json.loads(value)
                    except json.JSONDecodeError:
                        pass
                    config[key] = value
            data_dir = Path(kwargs['env']['TF_DATA_DIR'])
            backend_type = 'local' if 'path' in config else 's3'
            (data_dir / 'terraform.tfstate').write_text(json.dumps({'backend': {'type': backend_type, 'config': config}}))
        elif action == 'plan':
            output = next(arg[len('-out='):] for arg in command if arg.startswith('-out='))
            Path(output).write_bytes(b'exact saved terraform plan')
            self.approval = module.digest(Path(output))
        elif action not in ('show', 'apply'):
            self.fail('Unexpected Terraform action: ' + action)

    def assert_no_apply(self):
        self.assertFalse(any(command[0] == 'terraform' and command[2] == 'apply' for command in self.calls))

    def test_apply_uses_exact_saved_plan_and_consumes_review(self):
        self.invoke('plan')
        self.invoke('apply')
        command = next(command for command in self.calls if command[0] == 'terraform' and command[2] == 'apply')
        self.assertEqual(command[3:], ['-input=false', str(self.root / '.idp/plans/prod/network-apply.tfplan')])
        self.assertFalse(list((self.root / '.idp/plans/prod').iterdir()))

    def test_first_install_bootstraps_state_without_a_remote_bucket(self):
        self.invoke('plan', stack='state')
        planned = next(command for command in self.calls if command[0] == 'terraform' and command[2] == 'plan')
        self.assertIn('-chdir=' + str(self.root / 'infrastructure/terraform/stacks/bootstrap/state'), planned)
        self.assertFalse(any(arg.startswith('-var=cluster_name=') for arg in planned))
        self.assertTrue(any(arg.startswith('-var=state_bucket_name=') for arg in planned))
        metadata = json.loads((self.root / '.idp/plans/prod/state-apply.json').read_text())
        self.assertEqual(metadata['backend_type'], 'local')
        self.assertEqual(metadata['backend'], {'path': str(self.root / '.idp/state-bootstrap/prod/terraform.tfstate')})
        self.invoke('apply', stack='state')
        self.assertFalse(list((self.root / '.idp/plans/prod').iterdir()))

    def test_changed_source_or_wrong_approval_never_applies(self):
        self.invoke('plan')
        self.approval = 'unapproved'
        with self.assertRaises(ValueError):
            self.invoke('apply')
        self.source.write_text('# changed source\n')
        self.approval = module.digest(self.root / '.idp/plans/prod/network-apply.tfplan')
        with self.assertRaises(ValueError):
            self.invoke('apply')
        self.assert_no_apply()

    def test_new_retained_resources_block_a_previously_reviewed_destroy(self):
        self.invoke('plan', destroy=True)
        self.inventory = {'ResourceTagMappingList': [{'ResourceARN': 'retained-resource'}]}
        with self.assertRaises(ValueError):
            self.invoke('apply', destroy=True)
        self.assert_no_apply()

    def test_changed_state_blocks_destroy(self):
        self.invoke('plan', destroy=True)
        self.state['serial'] += 1
        with self.assertRaises(ValueError):
            self.invoke('apply', destroy=True)
        self.assert_no_apply()

    def test_unverifiable_inventory_blocks_destroy_planning(self):
        self.inventory = {}
        with self.assertRaises(ValueError):
            self.invoke('plan', destroy=True)
        self.assertFalse(any(command[0] == 'terraform' and command[2] == 'plan' for command in self.calls))

    def test_wrong_account_stops_before_terraform(self):
        self.account = '111111111111'
        with self.assertRaises(ValueError):
            self.invoke('plan')
        self.assertEqual(len(self.calls), 1)


if __name__ == "__main__":
    unittest.main()
