#!/usr/bin/env bash
# Shared config for screenshot scripts. Sourced by phaseN_*.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Load .env (VLLM_MODEL, VLLM_BASE_URL, OPENAI_API_KEY)
if [ -f "$ROOT/.env" ]; then
  set -a; . "$ROOT/.env"; set +a
fi

VLLM_BASE_URL="${VLLM_BASE_URL:-http://localhost:8000/v1}"
VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen3-30B-A3B-Instruct-2507}"
OPENAI_API_KEY="${OPENAI_API_KEY:-EMPTY}"
AGENT_URL="${AGENT_URL:-http://localhost:8001/answer}"
EVAL_SET="$ROOT/evals/eval_set.jsonl"

# Direct chat-completion call to vLLM. Args: <db> <question>
vllm_sql() {
  local db="$1" q="$2"
  curl -s "$VLLM_BASE_URL/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -d "$(jq -nc --arg m "$VLLM_MODEL" --arg q "$q" --arg db "$db" \
      '{model:$m,
        messages:[{role:"system",content:"You translate questions to SQLite SQL. Output only the SQL query, no prose."},
                  {role:"user",content:("DB: "+$db+"\nQuestion: "+$q)}],
        max_tokens:256, temperature:0}')" \
    | jq -r '.choices[0].message.content'
}

# Agent call. Args: <db> <question> [tags-json]
agent_answer() {
  local db="$1" q="$2" tags="${3:-{}}"
  curl -s -X POST "$AGENT_URL" -H "Content-Type: application/json" \
    -d "$(jq -nc --arg q "$q" --arg db "$db" --argjson tags "$tags" \
      '{question:$q, db:$db, tags:$tags}')"
}