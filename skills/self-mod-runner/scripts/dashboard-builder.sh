#!/bin/bash
# Thin wrapper — shared logic lives in core/dashboard/dashboard-builder.sh
# (de-duplicated from 15 identical per-skill copies, 2026-08-24).
exec bash "/home/cody/Documents/AI Brain Suite/AI_BRAIN_SUITE_COMPLETE/core/dashboard/dashboard-builder.sh" "$@"
