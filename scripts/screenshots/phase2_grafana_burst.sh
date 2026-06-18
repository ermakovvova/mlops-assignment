#!/usr/bin/env bash
# Phase 2 -> screenshots/grafana_serving.png
# Drives a burst so every Grafana panel (latency/throughput/KV) reacts.
# Run, then screenshot the full dashboard mid-burst.
#
# Usage: phase2_grafana_burst.sh [rps] [duration_seconds]
#   Prefers the agent load driver (full agent runs). Falls back to a raw
#   vLLM burst if the agent server is not up.
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

RPS="${1:-8}"
DUR="${2:-120}"

if curl -sf "${AGENT_URL%/answer}/health" >/dev/null 2>&1; then
  echo "Agent up -> driving $RPS rps for ${DUR}s via load_test/driver.py"
  uv run python "$ROOT/load_test/driver.py" --rps "$RPS" --duration "$DUR"
else
  echo "Agent down -> raw vLLM burst (${DUR}s)"
  end=$(( $(date +%s) + DUR ))
  while [ "$(date +%s)" -lt "$end" ]; do
    for _ in $(seq 1 "$RPS"); do
      vllm_sql financial "How many male clients in 'Hl.m. Praha' district?" >/dev/null &
    done
    wait
  done
fi
echo "done"