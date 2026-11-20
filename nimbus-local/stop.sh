#!/usr/bin/env bash
# Stop everything start.sh started. state/ is kept for reading afterwards.
here=$(cd "$(dirname "$0")" && pwd)
for pidfile in "$here"/state/run/*.pid; do
  [ -f "$pidfile" ] || continue
  kill -- -"$(cat "$pidfile")" 2>/dev/null || kill "$(cat "$pidfile")" 2>/dev/null || true
  rm -f "$pidfile"
done
echo stopped
