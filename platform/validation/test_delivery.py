import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import yaml

spec = importlib.util.spec_from_file_location('delivery', Path(__file__).with_name('delivery.py'))
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.cwd = Path.cwd()
        self.directory = tempfile.TemporaryDirectory(prefix='idp-delivery-test-')
        os.chdir(self.directory.name)
        self.path = Path('apps/identity-platform/api')
        self.path.mkdir(parents=True)
        self.write('delivery.json', json.dumps({'schemaVersion': 1, 'mode': 'source', 'container': 'app', 'owner': 'identity-platform', 'component': 'api'}))
        self.write('Dockerfile', 'FROM scratch\n')
        self.write('main.py', 'print("initial")\n')
        self.write('kustomization.yaml', 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n')
        self.write('deployment.yaml', 'apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: api, namespace: identity-platform}\nspec:\n  template:\n    spec:\n      containers:\n        - name: app\n          image: pending.invalid/app:pending\n')
        self.git('init', '-q')
        self.git('config', 'user.email', 'test@invalid.local')
        self.git('config', 'user.name', 'Test')
        self.git('add', '.')
        self.git('commit', '-qm', 'initial source')
        self.revision = self.git('rev-parse', 'HEAD').strip()

    def tearDown(self):
        os.chdir(self.cwd)
        self.directory.cleanup()

    def git(self, *args):
        return subprocess.check_output(['git', *args], text=True)

    def write(self, name, text):
        (self.path / name).write_text(text)

    def promote(self):
        with contextlib.redirect_stdout(io.StringIO()):
            delivery.promote(str(self.path), 'sha256:' + 'a' * 64, self.revision, self.revision)

    def test_pending_scaffold_does_not_deploy_before_digest_promotion(self):
        self.assertEqual(delivery.validate(self.path), [])
        self.promote()
        image = delivery.validate(self.path)[0]
        self.assertEqual(image, delivery.REGISTRY + '/idp-identity-platform-api@sha256:' + 'a' * 64)
        self.assertEqual(yaml.safe_load((self.path / 'kustomization.yaml').read_text())['resources'], ['deployment.yaml'])

    def test_stale_build_cannot_overwrite_new_source(self):
        self.write('main.py', 'print("new source")\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'new source')
        with self.assertRaisesRegex(ValueError, 'Source changed'):
            self.promote()
        self.assertEqual(delivery.validate(self.path), [])

    def test_manifest_only_merge_does_not_trigger_recursive_rebuild(self):
        self.promote()
        self.git('add', '.')
        self.git('commit', '-qm', 'promotion')
        self.assertEqual(delivery.inventory(self.revision), [])
        self.assertEqual(delivery.inventory(), [str(self.path)])

    def test_deleted_source_invalidates_an_earlier_build(self):
        (self.path / 'main.py').unlink()
        self.git('add', '.')
        self.git('commit', '-qm', 'remove source file')
        self.assertNotEqual(delivery.source_revision(self.path), self.revision)
        with self.assertRaisesRegex(ValueError, 'Source changed'):
            self.promote()

    def test_nested_source_named_like_delivery_metadata_triggers_rebuild(self):
        (self.path / 'src').mkdir()
        self.write('src/delivery.json', '{"runtime": true}\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'add runtime configuration')
        self.assertNotEqual(delivery.source_revision(self.path), self.revision)
        self.assertEqual(delivery.inventory(self.revision), [str(self.path)])

    def test_arbitrary_registry_or_tag_fails_even_when_release_metadata_matches(self):
        self.promote()
        filename = self.path / 'deployment.yaml'
        filename.write_text(filename.read_text().replace(delivery.REGISTRY + '/idp-identity-platform-api@sha256:' + 'a' * 64, 'docker.io/nginx:latest'))
        info = json.loads((self.path / 'delivery.json').read_text())
        info['release']['image'] = 'docker.io/nginx:latest'
        self.write('delivery.json', json.dumps(info))
        with self.assertRaisesRegex(ValueError, 'only this service ECR'):
            delivery.validate(self.path)

    def test_extra_workload_cannot_bypass_image_verification(self):
        self.promote()
        filename = self.path / 'deployment.yaml'
        filename.write_text(filename.read_text() + '\n---\napiVersion: batch/v1\nkind: Job\nmetadata: {name: bypass, namespace: identity-platform}\n')
        with self.assertRaisesRegex(ValueError, 'unsupported resource'):
            delivery.validate(self.path)

    def test_invalid_kustomization_fails_without_partial_manifest_write(self):
        original = (self.path / 'deployment.yaml').read_text()
        self.write('kustomization.yaml', 'resources: [../../outside.yaml]\n')
        with self.assertRaisesRegex(ValueError, 'Kustomize'):
            self.promote()
        self.assertEqual((self.path / 'deployment.yaml').read_text(), original)

    def test_kustomize_transforms_cannot_override_verified_release(self):
        self.promote()
        filename = self.path / 'kustomization.yaml'
        config = yaml.safe_load(filename.read_text())
        for key, value in {
            'images': [{'name': delivery.REGISTRY + '/idp-identity-platform-api', 'newName': 'docker.io/nginx', 'newTag': 'latest'}],
            'patches': [{'path': 'override.yaml'}],
            'components': ['../../other-service'],
            'configMapGenerator': [{'name': 'unreviewed', 'files': ['../../outside']}],
        }.items():
            with self.subTest(key=key):
                self.write('kustomization.yaml', yaml.safe_dump({**config, key: value}))
                with self.assertRaisesRegex(ValueError, 'Kustomize'):
                    delivery.validate(self.path)

    def test_disabled_service_cannot_bypass_contract_with_generators(self):
        config = yaml.safe_load((self.path / 'kustomization.yaml').read_text())
        self.write('kustomization.yaml', yaml.safe_dump({**config, 'generators': ['workload.yaml']}))
        with self.assertRaisesRegex(ValueError, 'Kustomize'):
            delivery.validate(self.path)

    def test_argocd_source_overrides_and_helm_detection_cannot_bypass_verification(self):
        self.promote()
        for name in ['.argocd-source.yaml', '.argocd-source-identity-platform-api.yaml', 'Chart.yaml']:
            with self.subTest(name=name):
                self.write(name, 'kustomize:\n  images: [docker.io/nginx:latest]\n')
                with self.assertRaisesRegex(ValueError, 'overrides and alternate renderers'):
                    delivery.validate(self.path)
                (self.path / name).unlink()

    def test_external_and_symlink_services_cannot_be_promoted(self):
        info = json.loads((self.path / 'delivery.json').read_text())
        info['mode'] = 'external'
        self.write('delivery.json', json.dumps(info))
        with self.assertRaisesRegex(ValueError, 'External'):
            self.promote()
        (self.path / 'escape').symlink_to('/tmp')
        with self.assertRaisesRegex(ValueError, 'symlinks'):
            delivery.validate(self.path)
