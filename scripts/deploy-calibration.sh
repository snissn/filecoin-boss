#!/usr/bin/env bash
set -euo pipefail
export BOSS_NETWORK=calibration
export BOSS_MANIFEST_OUTPUT=${BOSS_MANIFEST_OUTPUT:-deployments/calibration.json}
exec "$(dirname "$0")/deploy-network.sh"
