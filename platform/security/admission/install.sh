#!/usr/bin/env bash
set -euo pipefail
# Each candidate gets new names. Existing Deny bindings stay active throughout
# compilation and remain in place on every failure. Never downgrade to Audit.
exec python3 "$(dirname "${BASH_SOURCE[0]}")/rollout.py" "$@"
