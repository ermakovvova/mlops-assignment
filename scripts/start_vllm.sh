#!/usr/bin/env bash
#
# Start vLLM with your chosen configuration.
# Reference: https://docs.vllm.ai/en/latest/serving/openai_compatible_server.html

set -euo pipefail

MODEL="Qwen/Qwen3-30B-A3B-Instruct-2507"

# NOTE: every flag line except the last MUST end with a backslash, or the
# command stops there and the rest are silently dropped (or run as bogus
# standalone commands). `exec` also means nothing after this command runs.
# BF16 (no quantization): FP8 added KV concurrency that throughput didn't use
# and worsened p95 via the untuned FP8 MoE kernel. max-model-len 2048 buys ~46x
# concurrency on the same KV pool — prompts are <1.5k tokens, so it fits.
exec uv run python -m vllm.entrypoints.openai.api_server \
    --model "$MODEL" \
    --host 0.0.0.0 \
    --port 8000 \
    --max-model-len 2048 \
    --enable-prefix-caching \
    --gpu-memory-utilization 0.95
