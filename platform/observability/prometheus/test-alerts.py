#!/usr/bin/env python3
"""Run Prometheus's own rule engine against the chart's actual platform alerts."""
import argparse
from pathlib import Path
import subprocess
import tempfile

import yaml


HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--promtool', default='promtool')
    args = parser.parse_args()
    values = yaml.safe_load((HERE / 'values.yaml').read_text())
    with tempfile.TemporaryDirectory(prefix='idp-alert-tests-') as directory:
        target = Path(directory)
        rules = values['additionalPrometheusRulesMap']['platform-alerts']
        (target / 'platform-alerts.yaml').write_text(yaml.safe_dump(rules))
        (target / 'alerts.test.yaml').write_text((HERE / 'tests/alerts.test.yaml').read_text())
        subprocess.run([args.promtool, 'check', 'rules', 'platform-alerts.yaml'], cwd=target, check=True)
        subprocess.run([args.promtool, 'test', 'rules', 'alerts.test.yaml'], cwd=target, check=True)


if __name__ == '__main__':
    main()
