#!/usr/bin/env python3
"""Prove the image answers its declared HTTP health probe as an unprivileged user."""
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
import yaml

service, image = sys.argv[1:]
docs = list(yaml.safe_load_all((Path(service) / 'deployment.yaml').read_text()))
deployment = next(doc for doc in docs if doc and doc['kind'] == 'Deployment')
container = deployment['spec']['template']['spec']['containers'][0]
probe = container['readinessProbe'].get('httpGet')
if not probe:
    raise SystemExit('Source services require semantic HTTP health probes')
ports = {port['name']: port['containerPort'] for port in container['ports']}
port = ports.get(probe['port'], probe['port'])
identifier = subprocess.check_output(['docker', 'run', '-d', '--read-only', '--cap-drop=ALL', '--security-opt=no-new-privileges', '--user=1000:1000', '--tmpfs=/tmp:rw,noexec,nosuid,size=64m', '-p', f'127.0.0.1::{port}', image], text=True).strip()
try:
    address = subprocess.check_output(['docker', 'port', identifier, str(port)], text=True).strip()
    for attempt in range(30):
        try:
            with urllib.request.urlopen(f'http://{address}{probe["path"]}', timeout=2) as response:
                if response.status == 200 and response.read():
                    print('Unprivileged read-only container passed its health probe')
                    break
        except (OSError, ValueError):
            pass
        time.sleep(1)
    else:
        subprocess.run(['docker', 'logs', identifier], check=False)
        raise SystemExit('Container never passed its HTTP health probe')
finally:
    subprocess.run(['docker', 'rm', '-f', identifier], check=True)
