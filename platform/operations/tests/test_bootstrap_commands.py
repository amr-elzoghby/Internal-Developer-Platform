"""Exercise Make failure propagation without contacting AWS or Kubernetes."""
from contextlib import contextmanager
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class BootstrapCommandsTest(unittest.TestCase):
    @contextmanager
    def mocked_commands(self, network_status=0, render_status=23):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            log = directory / 'calls'
            config = directory / 'kubeconfig'
            config.touch()
            for name, body in {
                'python3': r'''printf 'python %s\n' "$*" >> "$MOCK_LOG"
case "$1" in
  */in-cluster.py) shift; exec "$@" ;;
  */network-policy.py) exit "$MOCK_NETWORK_STATUS" ;;
  */render-platform.py) exit "$MOCK_RENDER_STATUS" ;;
  *) exit 99 ;;
esac
''',
                'kubectl': 'printf "kubectl %s\\n" "$*" >> "$MOCK_LOG"\nexit 0\n',
                'helm': 'printf "helm %s\\n" "$*" >> "$MOCK_LOG"\nexit 0\n',
            }.items():
                binary = directory / name
                binary.write_text('#!/bin/sh\n' + body)
                binary.chmod(0o755)
            env = {key: value for key, value in os.environ.items()
                   if key not in ('MAKEFLAGS', 'MAKEFILES', 'GNUMAKEFLAGS', 'MFLAGS', 'MAKEOVERRIDES')}
            env.update(PATH=str(directory) + os.pathsep + os.environ['PATH'], MOCK_LOG=str(log),
                       KUBECONFIG=str(config), IDP_VERIFIED_KUBECONFIG=str(config),
                       MOCK_NETWORK_STATUS=str(network_status), MOCK_RENDER_STATUS=str(render_status))
            yield log, env

    def test_render_failure_stops_before_applying_or_starting_later_phases(self):
        with self.mocked_commands() as (log, env):
            for target, scope in [('_tenant-up', 'tenants'), ('_cluster-up', 'karpenter'),
                                  ('_crossplane-packages', 'runtimes'), ('_crossplane-compositions', 'compositions'),
                                  ('_argocd-up', 'gitops'), ('_platform-bootstrap-up', 'gitops')]:
                with self.subTest(target=target):
                    log.write_text('')
                    result = subprocess.run(['make', '--no-print-directory', target], cwd=ROOT, env=env,
                                            capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    calls = log.read_text()
                    self.assertIn('--scope ' + scope, calls)
                    self.assertNotIn('kubectl apply', calls)
                    self.assertNotIn('helm ', calls)
                    self.assertNotIn('_storage-up', result.stdout)
                    if target == '_cluster-up':
                        self.assertLess(calls.index('network-policy.py install'), calls.index('--scope karpenter'))
                    elif target in ('_tenant-up', '_argocd-up', '_platform-bootstrap-up'):
                        self.assertLess(calls.index('network-policy.py check'), calls.index('--scope ' + scope))

    def test_network_failure_blocks_tenant_and_gitops_activation(self):
        with self.mocked_commands(network_status=31) as (log, env):
            for target in ('_cluster-up', '_tenant-up', '_argocd-up', '_platform-bootstrap-up', '_health-check'):
                with self.subTest(target=target):
                    log.write_text('')
                    result = subprocess.run(['make', '--no-print-directory', target], cwd=ROOT, env=env,
                                            capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    calls = log.read_text()
                    action = 'install' if target == '_cluster-up' else 'check'
                    self.assertIn('network-policy.py ' + action, calls)
                    self.assertNotIn('render-platform.py', calls)
                    self.assertNotIn('kubectl ', calls)
                    self.assertNotIn('helm ', calls)


if __name__ == '__main__':
    unittest.main()
