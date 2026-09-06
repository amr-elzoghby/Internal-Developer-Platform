"""Exercise Make failure propagation without contacting AWS or Kubernetes."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class BootstrapCommandsTest(unittest.TestCase):
    def test_render_failure_stops_before_applying_or_starting_later_phases(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            log = directory / 'calls'
            config = directory / 'kubeconfig'
            config.touch()
            for name, body in {
                'python3': 'printf "render %s\\n" "$*" >> "$MOCK_LOG"\nexit 23\n',
                'kubectl': 'printf "kubectl %s\\n" "$*" >> "$MOCK_LOG"\nexit 0\n',
            }.items():
                binary = directory / name
                binary.write_text('#!/bin/sh\n' + body)
                binary.chmod(0o755)
            env = {key: value for key, value in os.environ.items()
                   if key not in ('MAKEFLAGS', 'MAKEFILES', 'GNUMAKEFLAGS', 'MFLAGS', 'MAKEOVERRIDES')}
            env.update(PATH=str(directory) + os.pathsep + os.environ['PATH'], MOCK_LOG=str(log),
                       KUBECONFIG=str(config), IDP_VERIFIED_KUBECONFIG=str(config))
            for target, scope in [('_tenant-up', 'tenants'), ('_cluster-up', 'karpenter'),
                                  ('_crossplane-packages', 'runtimes'), ('_crossplane-compositions', 'compositions')]:
                with self.subTest(target=target):
                    log.write_text('')
                    result = subprocess.run(['make', '--no-print-directory', target], cwd=ROOT, env=env,
                                            capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    calls = log.read_text()
                    self.assertIn('--scope ' + scope, calls)
                    self.assertNotIn('kubectl apply', calls)
                    self.assertNotIn('_storage-up', result.stdout)


if __name__ == '__main__':
    unittest.main()
