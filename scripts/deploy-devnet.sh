#!/usr/bin/env bash
set -euo pipefail
export BOSS_NETWORK=${BOSS_NETWORK:-devnet}
export BOSS_MANIFEST_OUTPUT=${BOSS_MANIFEST_OUTPUT:-deployments/devnet.json}
exec "$(dirname "$0")/deploy-network.sh"
