#!/usr/bin/env python3
"""Run ONLY from the trusted base checkout; parse candidate files without executing them."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

# The trusted module lives beside this script, never in the candidate checkout.
spec = importlib.util.spec_from_file_location('trusted_delivery', Path(__file__).with_name('delivery.py'))
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)


def main():
    candidate = Path(sys.argv[1]).resolve()
    os.chdir(candidate)
    repository = os.environ['GITHUB_REPOSITORY']
    images = []
    for path in sorted(Path('apps').glob('*/*')):
        if not path.is_dir():
            continue
        for image in delivery.validate(path):
            contract = json.loads((path / 'delivery.json').read_text())
            for predicate in ['https://slsa.dev/provenance/v1', 'https://spdx.dev/Document']:
                subprocess.run(['gh', 'attestation', 'verify', 'oci://' + image,
                                '--repo', repository,
                                '--signer-workflow', repository + '/.github/workflows/service-ci.yaml',
                                '--source-ref', 'refs/heads/main',
                                '--source-digest', contract['release']['buildRevision'],
                                '--deny-self-hosted-runners', '--predicate-type', predicate], check=True)
            subprocess.run(['docker', 'pull', image], check=True)
            images.append(image)
    Path(os.environ['RUNNER_TEMP'], 'verified-images').write_text('\n'.join(images) + ('\n' if images else ''))


if __name__ == '__main__':
    main()
