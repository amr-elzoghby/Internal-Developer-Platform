#!/usr/bin/env python3
"""Repository syntax/contracts; cloud-free and intentionally excludes local reports."""
import ast
import json
from pathlib import Path
import re
import subprocess
import yaml

ROOT = Path(__file__).resolve().parents[2]


def run(*command):
    subprocess.run(command, cwd=ROOT, check=True)


def main():
    paths = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard'], cwd=ROOT, text=True).splitlines()
    count = 0
    for name in sorted(set(paths)):
        path = ROOT / name
        if not path.is_file() or 'node_modules' in path.parts or '.terraform' in path.parts:
            continue
        if path.suffix in {'.yaml', '.yml', '.json', '.py', '.js', '.sh'}:
            text = path.read_text()
            if '${{ values.' in text:
                continue  # The actual Nunjucks render matrix validates skeleton output.
            if path.suffix in {'.yaml', '.yml'}:
                list(yaml.safe_load_all(text))
            elif path.suffix == '.json':
                json.loads(text)
            elif path.suffix == '.py':
                ast.parse(text, filename=name)
            elif path.suffix == '.js':
                run('node', '--check', name)
            elif path.suffix == '.sh':
                run('bash', '-n', name)
            count += 1
    for path in (ROOT / '.github/workflows').glob('*.yaml'):
        workflow = yaml.safe_load(path.read_text())
        for name, job in workflow['jobs'].items():
            if 'timeout-minutes' not in job:
                raise ValueError(f'{path}: job {name} lacks timeout')
            for step in job.get('steps', []):
                if 'uses' in step and not re.fullmatch(r'[^@]+@[0-9a-f]{40}', step['uses']):
                    raise ValueError(f'{path}: action must use a complete verified commit SHA')
    run('npm', 'test', '--prefix', 'platform/validation')
    run('python3', 'platform/validation/delivery.py', 'validate')
    print(f'Validated {count} repository source/config files and rendered service contracts')


if __name__ == '__main__':
    main()
