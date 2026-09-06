"""Execute Argo health Lua so stale controller conditions cannot advance sync waves."""
from pathlib import Path
import unittest

from lupa import LuaRuntime
import yaml


VALUES = Path(__file__).resolve().parents[2] / 'gitops/argocd/install/values.yaml'
CHECKS = yaml.safe_load(VALUES.read_text())['configs']['cm']
PREFIX = 'resource.customizations.health.'
READY_TYPES = {
    'CompositeResourceDefinition': 'Established',
    'Provider': 'Healthy',
    'Function': 'Healthy',
    'ManagedResourceActivationPolicy': 'Healthy',
}


def health(script, obj):
    lua = LuaRuntime()
    lua.globals().obj = lua.table_from(obj, recursive=True)
    return lua.execute(script)['status']


class ArgoHealthTest(unittest.TestCase):
    def controller_checks(self):
        for key, script in CHECKS.items():
            if key.startswith(PREFIX) and not key.endswith('_ValidatingAdmissionPolicy'):
                kind = key.rsplit('_', 1)[1]
                yield kind, script, READY_TYPES.get(kind, 'Ready')

    def test_missing_and_stale_readiness_cannot_advance_sync(self):
        for kind, script, ready_type in self.controller_checks():
            with self.subTest(kind=kind):
                obj = {'kind': kind, 'metadata': {'generation': 4}}
                self.assertEqual(health(script, obj), 'Progressing')
                obj['status'] = {'conditions': [{'type': ready_type, 'status': 'True', 'observedGeneration': 3}]}
                self.assertEqual(health(script, obj), 'Progressing')
                obj['status']['conditions'][0]['observedGeneration'] = 4
                self.assertEqual(health(script, obj), 'Healthy')
                obj['status']['observedGeneration'] = 3
                self.assertEqual(health(script, obj), 'Progressing')

    def test_current_reconciliation_failure_takes_precedence(self):
        for kind, script, ready_type in self.controller_checks():
            with self.subTest(kind=kind):
                obj = {'kind': kind, 'metadata': {'generation': 4}, 'status': {'conditions': [
                    {'type': ready_type, 'status': 'True', 'observedGeneration': 4},
                    {'type': 'Synced', 'status': 'False', 'observedGeneration': 4},
                ]}}
                self.assertEqual(health(script, obj), 'Degraded')
                obj['status']['conditions'][1]['observedGeneration'] = 3
                self.assertEqual(health(script, obj), 'Healthy')

    def test_controllers_without_condition_generation_remain_supported(self):
        for kind, script, ready_type in self.controller_checks():
            with self.subTest(kind=kind):
                obj = {'kind': kind, 'metadata': {'generation': 1}, 'status': {'conditions': [
                    {'type': ready_type, 'status': 'True'},
                ]}}
                self.assertEqual(health(script, obj), 'Healthy')

    def test_admission_waits_for_current_successful_type_check(self):
        script = CHECKS[PREFIX + 'admissionregistration.k8s.io_ValidatingAdmissionPolicy']
        obj = {'kind': 'ValidatingAdmissionPolicy', 'metadata': {'generation': 4},
               'status': {'observedGeneration': 3, 'typeChecking': {}}}
        self.assertEqual(health(script, obj), 'Progressing')
        obj['status']['observedGeneration'] = 4
        self.assertEqual(health(script, obj), 'Healthy')
        obj['status']['typeChecking']['expressionWarnings'] = [{'warning': 'invalid CEL'}]
        self.assertEqual(health(script, obj), 'Degraded')


if __name__ == '__main__':
    unittest.main()
