#!/usr/bin/env python3
"""Install platform connectivity before enforcing strict CNI startup for tenants."""
import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time

PLATFORM_NAMESPACES = ('kube-system', 'crossplane-system', 'argocd',
                       'external-secrets', 'reloader', 'monitoring')
POLICY_NAME = 'idp-platform-connectivity'


def platform_objects():
    objects = []
    for namespace in PLATFORM_NAMESPACES:
        objects.append({'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {
            'name': namespace, 'annotations': {
                'argocd.argoproj.io/sync-wave': '-60',
                'argocd.argoproj.io/sync-options': 'Prune=false,Delete=false'}}})
        # These platform namespaces previously had unrestricted IPv4 networking.
        # Argo's chart already restricts ingress; keep those rules authoritative.
        spec = {'podSelector': {}, 'policyTypes': ['Egress'],
                'egress': [{'to': [{'ipBlock': {'cidr': '0.0.0.0/0'}}]}]}
        if namespace != 'argocd':
            spec['policyTypes'].append('Ingress')
            spec['ingress'] = [{'from': [{'ipBlock': {'cidr': '0.0.0.0/0'}}]}]
        objects.append({'apiVersion': 'networking.k8s.io/v1', 'kind': 'NetworkPolicy',
                        'metadata': {'name': POLICY_NAME, 'namespace': namespace,
                                     'annotations': {'argocd.argoproj.io/sync-wave': '-59',
                                                     'argocd.argoproj.io/sync-options': 'Prune=false,Delete=false'}},
                        'spec': spec})
    return objects


def run(*command, payload=None):
    return subprocess.run(command, input=payload, text=True, capture_output=True, check=True).stdout


def aws(context, *args):
    return json.loads(run('aws', 'eks', *args, '--region', context['aws_region'], '--output', 'json'))


def addon(context):
    return aws(context, 'describe-addon', '--cluster-name', context['cluster_name'],
               '--addon-name', 'vpc-cni')['addon']


def strict_configuration(configuration):
    result = copy.deepcopy(configuration)
    result['enableNetworkPolicy'] = 'true'
    result.setdefault('env', {})['NETWORK_POLICY_ENFORCING_MODE'] = 'strict'
    return result


def verify_configuration(observed, daemonset):
    config = json.loads(observed.get('configurationValues') or '{}')
    if (observed.get('status') != 'ACTIVE' or config.get('enableNetworkPolicy') not in ('true', True)
            or config.get('env', {}).get('NETWORK_POLICY_ENFORCING_MODE') != 'strict'):
        raise ValueError('Strict CNI configuration is not active; run make network-policy-up first')
    containers = {item['name']: item for item in daemonset['spec']['template']['spec']['containers']}
    env = {item['name']: item.get('value') for item in containers.get('aws-node', {}).get('env', [])}
    if (env.get('NETWORK_POLICY_ENFORCING_MODE') != 'strict'
            or '--enable-network-policy=true' not in containers.get('aws-eks-nodeagent', {}).get('args', [])):
        raise ValueError('The running CNI template does not enforce strict network policies')
    status = daemonset.get('status', {})
    desired = status.get('desiredNumberScheduled', 0)
    if (not desired or status.get('observedGeneration') != daemonset['metadata'].get('generation')
            or any(status.get(field) != desired for field in ('updatedNumberScheduled', 'numberReady', 'numberAvailable'))):
        raise ValueError('The strict CNI DaemonSet has not finished its rollout on every node')


def check(context):
    observed = addon(context)
    daemonset = json.loads(run('kubectl', 'get', 'daemonset/aws-node', '-n', 'kube-system', '-o', 'json'))
    verify_configuration(observed, daemonset)
    for obj in platform_objects():
        if obj['kind'] == 'NetworkPolicy':
            live = json.loads(run('kubectl', 'get', 'networkpolicy/' + POLICY_NAME,
                                  '-n', obj['metadata']['namespace'], '-o', 'json'))
            if live.get('spec') != obj['spec']:
                raise ValueError('Platform connectivity policy drift; run make network-policy-up')


def wait_update(context, identifier):
    deadline = time.monotonic() + 600
    while time.monotonic() < deadline:
        update = aws(context, 'describe-update', '--name', context['cluster_name'],
                     '--addon-name', 'vpc-cni', '--update-id', identifier)['update']
        if update['status'] == 'Successful':
            return
        if update['status'] in ('Failed', 'Cancelled'):
            raise RuntimeError('CNI update failed: ' + json.dumps(update.get('errors', [])))
        time.sleep(2)
    raise TimeoutError('CNI update timed out; tenant bootstrap remains blocked')


def install(context):
    observed = addon(context)
    if observed.get('status') != 'ACTIVE':
        raise ValueError('Wait for the existing VPC CNI add-on operation before changing enforcement')
    objects = platform_objects()
    run('kubectl', 'apply', '--server-side', '--field-manager=idp-network-policy', '-f', '-',
        payload=json.dumps({'apiVersion': 'v1', 'kind': 'List', 'items': objects}))
    configuration = json.loads(observed.get('configurationValues') or '{}')
    wanted = strict_configuration(configuration)
    if wanted != configuration:
        update = aws(context, 'update-addon', '--cluster-name', context['cluster_name'],
                     '--addon-name', 'vpc-cni', '--resolve-conflicts', 'PRESERVE',
                     '--configuration-values', json.dumps(wanted))
        wait_update(context, update['update']['id'])
    run('aws', 'eks', 'wait', 'addon-active', '--cluster-name', context['cluster_name'],
        '--addon-name', 'vpc-cni', '--region', context['aws_region'])
    run('kubectl', 'rollout', 'status', 'daemonset/aws-node', '-n', 'kube-system', '--timeout=600s')
    run('kubectl', 'rollout', 'status', 'deployment/coredns', '-n', 'kube-system', '--timeout=180s')
    check(context)
    print('Strict CNI startup and platform connectivity verified; tenant bootstrap may proceed.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['install', 'check', 'render'])
    args = parser.parse_args()
    if args.action == 'render':
        print(json.dumps({'apiVersion': 'v1', 'kind': 'List', 'items': platform_objects()}))
        return
    snapshot = os.environ.get('IDP_VERIFIED_KUBECONFIG', '')
    if not snapshot or os.environ.get('KUBECONFIG') != snapshot or not Path(snapshot).is_file():
        parser.error('Run make network-policy-up or a guarded tenant/GitOps target')
    spec = importlib.util.spec_from_file_location('verified_cluster', Path(__file__).with_name('in-cluster.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    context = module.read_environment()
    if args.action == 'install':
        install(context)
    else:
        check(context)


if __name__ == '__main__':
    main()
