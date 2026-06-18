#!/usr/bin/env bash
# Phase 5 -> screenshots/grafana_eval_run.png
# Runs the baseline eval (~30 questions x ~2 vLLM calls). Screenshot Grafana mid-run.
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo "Running baseline eval -> results/eval_baseline.json"
echo "Screenshot the Grafana dashboard while this runs."
uv run python "$ROOT/evals/run_eval.py"