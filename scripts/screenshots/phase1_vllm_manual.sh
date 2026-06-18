#!/usr/bin/env bash
# Phase 1 -> screenshots/vllm_manual_query.png
# Fires the first 5 questions from evals/eval_set.jsonl directly at vLLM.
# Screenshot this terminal output (5 questions -> 5 SQL responses).
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

N="${1:-5}"
echo "vLLM: $VLLM_BASE_URL  model: $VLLM_MODEL"
echo

i=0
while IFS= read -r line; do
  q=$(echo "$line" | jq -r .question)
  db=$(echo "$line" | jq -r .db_id)
  echo "### Q$i [$db]"
  echo "$q"
  echo "--- SQL ---"
  vllm_sql "$db" "$q"
  echo; echo
  i=$((i+1)); [ "$i" -ge "$N" ] && break
done < "$EVAL_SET"