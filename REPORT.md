# REPORT

## Phase 1: vLLM Configuration

### Model
- **Model:** `Qwen/Qwen3-30B-A3B-Instruct-2507`
- **Hardware:** 1× NVIDIA H100 80GB HBM3

### Launch Configuration

```bash
uv run python -m vllm.entrypoints.openai.api_server \
    --model Qwen/Qwen3-30B-A3B-Instruct-2507 \
    --host 0.0.0.0 \
    --port 8000 \
    --max-model-len 32768
```

### Configuration Flags

| Flag | Value | Justification |
|------|-------|---------------|
| `--max-model-len` | 8192 | Model defaults to 262k context requiring 24 GiB KV cache, but only ~8.6 GiB remains after loading 57 GiB of weights. 8k fits comfortably and is sufficient for text-to-SQL prompts (1.5-3k tokens). |
| `--host` | 0.0.0.0 | Bind to all interfaces so Prometheus (in Docker) can scrape `/metrics`. |
| `--port` | 8000 | Default vLLM port, matches Prometheus scrape config. |

### Issues Encountered

1. **`transformers` version incompatibility:** vLLM 0.9.x called `tokenizer.all_special_tokens_extended` which was removed in transformers 5.x. Fixed by pinning `transformers>=4.48,<4.52` in `pyproject.toml`.

2. **Missing Python headers:** Triton's CUDA driver shim needs `Python.h` to compile. Fixed with `sudo apt install python3.12-dev`.

3. **KV cache OOM:** Model weights occupy ~57 GiB on the H100 80GB, leaving ~8.6 GiB for KV cache. The default 262k context needs 24 GiB. Reduced via `--max-model-len 32768`.

### Observability Stack

All running via `docker compose up -d`:

- **Prometheus** (port 9090) — scrapes vLLM `/metrics` every 5s via `host.docker.internal:8000`
- **Grafana** (port 3000) — auto-provisioned with Prometheus datasource and starter dashboard
- **Langfuse** (port 3001) — local instance for agent tracing (Phase 4)
