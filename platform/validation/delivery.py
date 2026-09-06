#!/usr/bin/env python3
"""Validated service inventory and digest promotion; no cloud mutations."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

import yaml

REGISTRY = '851236938302.dkr.ecr.us-east-1.amazonaws.com'
TEAMS = {'identity-platform', 'platform-engineering', 'data-platform'}
NAME = re.compile(r'^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$')
DIGEST = re.compile(r'^sha256:[0-9a-f]{64}$')
DELIVERY_FILES = {'deployment.yaml', 'kustomization.yaml', 'catalog-info.yaml', 'delivery.json', 'mkdocs.yml'}


def service_path(value):
    path = Path(value)
    if len(path.parts) != 3 or path.parts[0] != 'apps' or path.parts[1] not in TEAMS or not NAME.fullmatch(path.parts[2]):
        raise ValueError('Expected apps/<approved-team>/<DNS service name, max 40>')
    if any(parent.is_symlink() for parent in [path, *path.parents]) or any(item.is_symlink() for item in path.rglob('*')):
        raise ValueError('Service paths cannot contain symlinks')
    return path


def contract(path):
    path = service_path(str(path))
    info = json.loads((path / 'delivery.json').read_text())
    if info.get('schemaVersion') != 1 or info.get('mode') not in {'source', 'external'}:
        raise ValueError(f'{path}: missing supported delivery contract')
    if info.get('owner') != path.parts[1] or info.get('component') != path.name:
        raise ValueError(f'{path}: owner/component mismatch')
    if not NAME.fullmatch(info.get('container', '')):
        raise ValueError(f'{path}: invalid container name')
    return info


def source_revision(path):
    path = service_path(str(path))
    # Match the source directory in history so deletions also invalidate builds.
    paths = [str(path), *[f':(top,exclude,literal){path}/{name}' for name in sorted(DELIVERY_FILES)],
             f':(top,exclude,glob){path}/docs/**']
    files = subprocess.check_output(['git', 'ls-files', '-z', '--', *paths], text=True)
    if not files:
        raise ValueError(f'{path}: no tracked build source')
    return subprocess.check_output(['git', 'log', '-1', '--format=%H', '--', *paths], text=True).strip()


def delivery_only_change(name):
    parts = Path(name).parts
    return (len(parts) >= 4 and parts[0] == 'apps' and parts[1] in TEAMS
            and ((len(parts) == 4 and parts[3] in DELIVERY_FILES) or parts[3] == 'docs'))


def kustomization(path):
    if any(path.glob('.argocd-source*.yaml')) or (path / 'Chart.yaml').exists():
        raise ValueError(f'{path}: Argo CD source overrides and alternate renderers are forbidden')
    config = yaml.safe_load((path / 'kustomization.yaml').read_text())
    if (not isinstance(config, dict) or set(config) - {'apiVersion', 'kind', 'resources'}
            or config.get('apiVersion') != 'kustomize.config.k8s.io/v1beta1'
            or config.get('kind') != 'Kustomization'
            or config.get('resources') not in [[], ['deployment.yaml']]):
        raise ValueError(f'{path}: unsupported Kustomize resource contract; transforms and generators are forbidden')
    return config


def inventory(changed_since=None):
    if changed_since and re.fullmatch('[0-9a-f]{40}', changed_since) and changed_since != '0' * 40:
        changed = subprocess.check_output(['git', 'diff', '--name-only', changed_since, 'HEAD'], text=True).splitlines()
        if changed and all(delivery_only_change(name) for name in changed):
            return []  # Promotion-only merges do not recursively rebuild themselves.
    result = []
    for path in sorted(Path('apps').glob('*/*')):
        if not path.is_dir():
            continue
        info = contract(path)
        if info['mode'] == 'source':
            if not (path / 'Dockerfile').is_file():
                raise ValueError(f'{path}: source service requires Dockerfile')
            result.append(str(path))
    return result


def promote(path, digest, revision, build_revision):
    path = service_path(path)
    info = contract(path)
    if info['mode'] != 'source':
        raise ValueError('External artifacts require an owner-verified migration; source CI cannot release them')
    if not DIGEST.fullmatch(digest) or not all(value and re.fullmatch('[0-9a-f]{40}', value) for value in [revision, build_revision]):
        raise ValueError('Digest/source revision malformed')
    if source_revision(path) != revision:
        raise ValueError('Source changed since build; refuse stale promotion. The next delivery sweep rebuilds it.')
    image = f'{REGISTRY}/idp-{info["owner"]}-{info["component"]}@{digest}'
    filename = path / 'deployment.yaml'
    docs = list(yaml.safe_load_all(filename.read_text()))
    deployments = [doc for doc in docs if doc and doc.get('kind') == 'Deployment']
    if len(deployments) != 1:
        raise ValueError('Expected exactly one Deployment')
    containers = deployments[0]['spec']['template']['spec']['containers']
    matches = [item for item in containers if item['name'] == info['container']]
    if len(matches) != 1:
        raise ValueError('Named application container missing or ambiguous')
    matches[0]['image'] = image
    config = kustomization(path)
    config['resources'] = ['deployment.yaml']
    info['release'] = {'image': image, 'sourceRevision': revision, 'buildRevision': build_revision}
    # Validate every input before writing any of the three promotion files.
    filename.write_text(yaml.safe_dump_all(docs, sort_keys=False))
    (path / 'kustomization.yaml').write_text(yaml.safe_dump(config, sort_keys=False))
    (path / 'delivery.json').write_text(json.dumps(info, indent=2) + '\n')
    print(image)


def validate(path):
    path = service_path(str(path))
    info = contract(path)
    config = kustomization(path)
    resources = config.get('resources')
    if resources == []:
        if info.get('release'):
            raise ValueError(f'{path}: disabled service cannot declare an active release')
        return []
    if resources != ['deployment.yaml']:
        raise ValueError(f'{path}: unexpected deployment resources')
    if info['mode'] == 'external':
        raise ValueError(f'{path}: external artifact quarantined until source and attestations are recovered')
    release = info.get('release', {})
    images = []
    for doc in yaml.safe_load_all((path / 'deployment.yaml').read_text()):
        if not doc or doc.get('kind') not in {'Deployment', 'Service', 'HorizontalPodAutoscaler', 'PodDisruptionBudget'}:
            raise ValueError(f'{path}: unsupported resource; extend the reviewed service contract first')
        if doc.get('metadata', {}).get('namespace') != path.parts[1]:
            raise ValueError(f'{path}: resource must target the owning tenant namespace')
        if doc and doc.get('kind') == 'Deployment':
            spec = doc['spec']['template']['spec']
            for container in spec.get('containers', []) + spec.get('initContainers', []):
                image = container['image']
                expected = f'{REGISTRY}/idp-{path.parts[1]}-{path.name}@'
                if not image.startswith(expected) or not DIGEST.fullmatch(image[len(expected):]):
                    raise ValueError(f'{path}: only this service ECR repository and SHA256 digest may deploy')
                images.append(image)
    if len(images) != 1 or images[0] != release.get('image'):
        raise ValueError(f'{path}: release/image metadata inconsistent')
    if not all(re.fullmatch('[0-9a-f]{40}', release.get(key, '')) for key in ['sourceRevision', 'buildRevision']):
        raise ValueError(f'{path}: release must identify source and build commits')
    return images


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['inventory', 'revision', 'promote', 'validate', 'images'])
    parser.add_argument('path', nargs='?')
    parser.add_argument('--changed-since')
    parser.add_argument('--digest')
    parser.add_argument('--revision')
    parser.add_argument('--build-revision')
    args = parser.parse_args()
    if args.command == 'inventory':
        print(json.dumps(inventory(args.changed_since)))
    elif args.command == 'revision':
        print(source_revision(service_path(args.path)))
    elif args.command == 'promote':
        promote(args.path, args.digest, args.revision, args.build_revision)
    else:
        images = []
        for path in sorted(Path('apps').glob('*/*')):
            if path.is_dir():
                images.extend(validate(path))
        if args.command == 'images':
            print('\n'.join(sorted(set(images))))
        else:
            print('Delivery contracts valid')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, FileNotFoundError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
