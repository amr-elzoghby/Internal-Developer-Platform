"""Execute the actual admission CEL with cel-python; Kubernetes type checks remain live."""
import copy
from pathlib import Path
import unittest

import celpy
from celpy.adapter import json_to_cel
import yaml

POLICY = Path(__file__).resolve().parents[2] / 'security/admission/tenant-infrastructure-policy.yaml'
DEFINITION = yaml.safe_load(POLICY.read_text())
ENV = celpy.Environment()
VARIABLES = [(item['name'], ENV.program(ENV.compile(item['expression']))) for item in DEFINITION['spec']['variables']]
CHECKS = [ENV.program(ENV.compile(item['expression'])) for item in DEFINITION['spec']['validations']]


def claim():
    return {'kind': 'PostgresSQLInstance',
            'metadata': {'namespace': 'identity-platform', 'annotations': {'argocd.argoproj.io/sync-options': 'Prune=false,Delete=false'}},
            'spec': {'owner': 'identity-platform', 'expiresOn': '2026-12-31', 'crossplane': {'compositionUpdatePolicy': 'Manual'}}}


def admitted(obj, old=None, username='tenant-user', groups=()):
    context = {key: json_to_cel(value) for key, value in {
        'object': obj, 'oldObject': old,
        'namespaceObject': {'metadata': {'name': 'identity-platform'}},
        'request': {'operation': 'CREATE' if old is None else 'UPDATE', 'userInfo': {'username': username, 'groups': list(groups)}},
        'variables': {},
    }.items()}
    for name, program in VARIABLES:
        context['variables'][celpy.celtypes.StringType(name)] = program.evaluate(context)
    return all(bool(program.evaluate(context)) for program in CHECKS)


class InfrastructureAdmissionTest(unittest.TestCase):
    def test_valid_initial_claim_and_controller_defaults(self):
        original = claim()
        self.assertTrue(admitted(original))
        updated = copy.deepcopy(original)
        updated['spec']['crossplane'].update({'compositionRef': {'name': 'postgressqlinstances.idp.io'},
                                             'compositionRevisionRef': {'name': 'postgressqlinstances.idp.io-abc123'},
                                             'resourceRefs': [{'apiVersion': 'rds.aws.m.upbound.io/v1beta1', 'kind': 'Instance', 'name': 'db'}]})
        self.assertTrue(admitted(updated, original, 'system:serviceaccount:crossplane-system:crossplane'))
        self.assertTrue(admitted(updated, updated))

    def test_wrong_tenant_and_ownership_reassignment_fail(self):
        obj = claim()
        obj['spec']['owner'] = 'data-platform'
        self.assertFalse(admitted(obj))
        self.assertFalse(admitted(obj, claim(), groups=['idp:platform-admins']))

    def test_automatic_and_selectors_fail_even_for_admin(self):
        for field, value in [('compositionUpdatePolicy', 'Automatic'), ('compositionSelector', {'matchLabels': {'bypass': 'true'}}),
                             ('compositionRevisionSelector', {'matchLabels': {'bypass': 'true'}}), ('compositionRef', {'name': 'other'})]:
            with self.subTest(field=field):
                obj = claim()
                obj['spec']['crossplane'][field] = value
                self.assertFalse(admitted(obj, groups=['idp:platform-admins']))

    def test_initial_or_changed_revision_requires_platform_writer(self):
        obj = claim()
        obj['spec']['crossplane']['compositionRevisionRef'] = {'name': 'postgressqlinstances.idp.io-abc123'}
        self.assertFalse(admitted(obj))
        self.assertFalse(admitted(obj, claim(), groups=['idp:tenant:platform-engineering:operator']))
        self.assertTrue(admitted(obj, claim(), groups=['idp:platform-admins']))
        self.assertTrue(admitted(obj, claim(), 'system:serviceaccount:argocd:argocd-application-controller'))

    def test_missing_or_corrupt_retention_options_fail(self):
        for options in ['', 'Prune=false', 'Prune=falsehood,Delete=false', 'Prune=true,Delete=false']:
            obj = claim()
            obj['metadata']['annotations']['argocd.argoproj.io/sync-options'] = options
            self.assertFalse(admitted(obj))
        obj = claim()
        del obj['metadata']['annotations']
        self.assertFalse(admitted(obj))

    def test_review_date_requires_approved_renewal(self):
        obj = claim()
        obj['spec']['expiresOn'] = '2027-12-31'
        self.assertFalse(admitted(obj, claim()))
        self.assertTrue(admitted(obj, claim(), groups=['idp:platform-admins']))
        obj['spec']['expiresOn'] = 'never'
        self.assertFalse(admitted(obj))


if __name__ == '__main__':
    unittest.main()
