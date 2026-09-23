#!/usr/bin/env bash
# Deprecated name kept for the old cron path. The sidecar watchdog is the real check.
exec "$(cd "$(dirname "$0")" && pwd)/sidecar-watchdog.sh" "$@"
