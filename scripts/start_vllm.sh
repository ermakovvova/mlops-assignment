#!/usr/bin/env bash
#
# Start vLLM with your chosen configuration.
# Reference: https://docs.vllm.ai/en/latest/serving/openai_compatible_server.html

set -euo pipefail

MODEL="Qwen/Qwen3-30B-A3B-Instruct-2507"

# NOTE: every flag line except the last MUST end with a backslash, or the
# command stops there and the rest are silently dropped (or run as bogus
# standalone commands). `exec` also means nothing after this command runs.
exec uv run python -m vllm.entrypoints.openai.api_server \
    --model "$MODEL" \
    --host 0.0.0.0 \
    --port 8000 \
    --max-model-len 4096 \
    --enable-prefix-caching \
    --gpu-memory-utilization 0.95
