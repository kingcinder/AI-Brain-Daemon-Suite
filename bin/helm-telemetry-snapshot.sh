#!/bin/bash
# helm-telemetry-snapshot.sh — thin wrapper for the telemetry page renderer.
exec /usr/bin/python3 "$HOME/.juno-brain/bin/helm-telemetry-snapshot.py" "$@"
