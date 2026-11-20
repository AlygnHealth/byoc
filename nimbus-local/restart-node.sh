#!/usr/bin/env bash
# Restart only the nimbus node, optionally with another compiled node:
#   ./restart-node.sh [file.uc]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
L="$here/state"
IMAGE="$here/../nimbus-image"
NODE_UC=${1:-$IMAGE/nodeMain.uc}
if [ -f "$L/run/nimbus.pid" ]; then kill -- -"$(cat "$L/run/nimbus.pid")" 2>/dev/null || true; sleep 2; fi
# The node's output is timestamped into state/events.tsv, which the fake CloudWatch reads.
setsid nohup bash -c "NIMBUS_CONFIG_FILE='$L/run/config-merged.json' '$IMAGE/unison' run.compiled '$NODE_UC' 2>&1 | python3 -I '$here/fake_cloudwatch.py' stamp '$L/events.tsv'" > "$L/nimbus.log" 2>&1 < /dev/null &
echo $! > "$L/run/nimbus.pid"
until grep -q "location registered" "$L/nimbus.log" 2>/dev/null; do sleep 1; done
echo "node up ($NODE_UC); its output is in $L/nimbus.log"
