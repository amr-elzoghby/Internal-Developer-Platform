#!/usr/bin/env python3
"""Reject public Argo bootstrap accounts and incomplete optional OIDC values."""
import copy
from pathlib import Path
import re
import sys
from urllib.parse import urlparse

import yaml


def merge(base, overlay):
    result = copy.deepcopy(base)
    for key, value in overlay.items():
        result[key] = merge(result[key], value) if isinstance(value, dict) and isinstance(result.get(key), dict) else value
    return result


def enabled(value):
    return value is True or str(value).lower() == 'true'


def https_origin(value):
    parsed = urlparse(str(value))
    return parsed.scheme == 'https' and bool(parsed.hostname) and not parsed.username and not parsed.password and 'REPLACE_' not in value


def validate(values, oidc_required=False):
    cm = values['configs']['cm']
    ingress = values.get('server', {}).get('ingress', {})
    oidc_text = cm.get('oidc.config', '')
    if enabled(cm.get('users.anonymous.enabled', False)):
        raise ValueError('Anonymous Argo access must remain disabled')
    if enabled(ingress.get('enabled', False)) or oidc_required or oidc_text:
        if enabled(cm.get('admin.enabled', True)):
            raise ValueError('Disable the shared admin account when enabling OIDC or external ingress')
        if not https_origin(cm.get('url', '')):
            raise ValueError('A real HTTPS Argo URL is required for OIDC callbacks')
        oidc = yaml.safe_load(oidc_text) or {}
        if not https_origin(oidc.get('issuer', '')):
            raise ValueError('A real HTTPS OIDC issuer is required')
        if not oidc.get('clientID') or 'REPLACE_' in oidc['clientID']:
            raise ValueError('A real OIDC client ID is required')
        if not re.fullmatch(r'\$[a-z0-9]([-a-z0-9]*[a-z0-9])?:[A-Za-z0-9_.-]+', oidc.get('clientSecret', '')):
            raise ValueError('Use a reference to a labelled Kubernetes Secret, never a plaintext OIDC client secret')
        if enabled(oidc.get('skipAudienceCheckWhenTokenHasNoAudience', False)):
            raise ValueError('OIDC audience checking cannot be disabled')
        if 'groups' not in oidc.get('requestedScopes', []):
            raise ValueError('OIDC must request the groups claim used by Argo RBAC')
        rbac = values['configs']['rbac']
        if rbac.get('policy.default') != 'role:authenticated':
            raise ValueError('Default authenticated users must retain zero implicit permissions')
        if not rbac.get('policy.csv') or 'REPLACE_' in rbac['policy.csv']:
            raise ValueError('Explicit real OIDC group mappings are required')
    return values


def main():
    values = yaml.safe_load(Path(sys.argv[1]).read_text())
    for path in sys.argv[2:]:
        values = merge(values, yaml.safe_load(Path(path).read_text()))
    validate(values, oidc_required=len(sys.argv) > 2)
    print('Argo private-access/OIDC values contract passed')


if __name__ == '__main__':
    main()
