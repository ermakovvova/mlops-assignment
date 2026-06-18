#!/usr/bin/env bash
# Phase 3 -> verify->revise smoke test (no screenshot, evidence for report).
# Fires 5 eval questions at the agent. Look for iterations>0 == a revise fired.
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

N="${1:-5}"
i=0
while IFS= read -r line; do
  q=$(echo "$line" | jq -r .question)
  db=$(echo "$line" | jq -r .db_id)
  echo "### Q$i [$db] $q"
  agent_answer "$db" "$q" | jq '{ok, iterations, sql}'
  echo
  i=$((i+1)); [ "$i" -ge "$N" ] && break
done < "$EVAL_SET"