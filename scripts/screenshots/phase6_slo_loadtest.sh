#!/usr/bin/env bash
# Phase 6 -> screenshots/grafana_before.png / grafana_after.png
# Runs the SLO load test (P95 < 5s, 10+ rps, 5 min window).
# Run once BEFORE your config change (screenshot -> grafana_before.png),
# apply ONE change + restart vLLM, run again (screenshot -> grafana_after.png).
#
# Usage: phase6_slo_loadtest.sh [rps] [duration_seconds]
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

RPS="${1:-10}"
DUR="${2:-300}"

echo "SLO load test: $RPS rps for ${DUR}s. Screenshot Grafana at steady state."
uv run python "$ROOT/load_test/driver.py" --rps "$RPS" --duration "$DUR"