#!/usr/bin/env bash
# Phase 4 -> screenshots/langfuse_trace.png + screenshots/langfuse_tags.png
# Fires 10 tagged eval questions at the agent.
#  - langfuse_tags.png : trace list filtered on phase=phase4 (tags visible)
#  - langfuse_trace.png: open a trace with iterations>=1 -> generate_sql/verify/revise waterfall
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

N="${1:-10}"
i=0
while IFS= read -r line; do
  q=$(echo "$line" | jq -r .question)
  db=$(echo "$line" | jq -r .db_id)
  tags=$(jq -nc --arg i "$i" '{phase:"phase4", run:"trace-demo", qid:$i}')
  printf 'Q%s [%s] ' "$i" "$db"
  agent_answer "$db" "$q" "$tags" | jq -c '{ok, iterations}'
  i=$((i+1)); [ "$i" -ge "$N" ] && break
done < "$EVAL_SET"

echo
echo "Open Langfuse (http://localhost:3001):"
echo "  - filter traces on tag phase=phase4  -> langfuse_tags.png"
echo "  - open a trace above with iterations>=1 -> langfuse_trace.png"