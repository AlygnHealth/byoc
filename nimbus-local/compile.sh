#!/usr/bin/env bash
# Compile main.nodeMain with a scratch file applied, in a copy of the codebase,
# so nothing changes in the real one:
#   ./compile.sh <project/branch> [scratch.u]    # writes state/nodeMain.uc
# then ./restart-node.sh state/nodeMain.uc. Needs the UCM in ../nimbus-image
# (`ucm version` must match it: a .uc runs only on the UCM that wrote it).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$here/state/compile"
branch=$1; scratch=${2:-}
{
  echo '```ucm'
  [ -n "$scratch" ] && { echo "$branch> load $(realpath "$scratch")"; echo "$branch> update"; }
  echo "$branch> compile main.nodeMain $here/state/nodeMain"
  echo '```'
} > "$here/state/compile/compile.md"
cd "$here/state/compile"
ucm --codebase "$HOME" transcript.fork compile.md > compile.log 2>&1 || { tail -30 compile.log; exit 1; }
grep -o '/tmp/transcript-[0-9a-f]*' compile.log | head -1 | xargs -r rm -rf
echo "compiled $here/state/nodeMain.uc"
