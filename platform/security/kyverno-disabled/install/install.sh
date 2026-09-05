#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'Kyverno is archived and is not approved for this cluster version.' 'Use make admission-up for the supported native admission controls.' >&2
exit 1
