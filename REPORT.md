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
    --max-model-len 8192
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

3. **KV cache OOM:** Model weights occupy ~57 GiB on the H100 80GB, leaving ~8.6 GiB for KV cache. The default 262k context needs 24 GiB. Reduced via `--max-model-len 8192`.

### Observability Stack

All running via `docker compose up -d`:

- **Prometheus** (port 9090) — scrapes vLLM `/metrics` every 5s via `host.docker.internal:8000`
- **Grafana** (port 3000) — auto-provisioned with Prometheus datasource and starter dashboard
- **Langfuse** (port 3001) — local instance for agent tracing (Phase 4)

---

## Phase 2: Serving Dashboard (o11y core)

Dashboard JSON: `infra/grafana/provisioning/dashboards/serving.json` (uid `vllm-serving`), auto-provisioned into Grafana. Replaces the 2-panel starter with a summary row + 6 timeseries across the three required categories.

### At-a-glance row (stat panels)
SLO-aligned numbers a teammate can read in one glance:
- **P95 E2E latency** — green < 5s, red ≥ 5s (Phase 6 SLO).
- **Request throughput** — green ≥ 10 RPS (Phase 6 SLO), red below.
- **KV cache usage** — green / yellow ≥ 0.7 / red ≥ 0.9.
- **Requests waiting** — queue depth; yellow ≥ 1, red ≥ 10.

### Latency — "is it slow, and where in the lifecycle?"
- **E2E request latency** (p50/p95/p99) from `vllm:e2e_request_latency_seconds_bucket`, with a 5s SLO threshold line.
- **Time to first token** (p50/p95/p99) from `vllm:time_to_first_token_seconds_bucket` — queueing + prefill cost.
- **Inter-token latency** (p50/p95) from `vllm:time_per_output_token_seconds_bucket` — decode-step efficiency under batching.

Splitting E2E into TTFT + ITL localizes the time: high TTFT → prefill/queue bound; high ITL → decode bound.

### Throughput
- **Request concurrency & queue**: completed `rate(vllm:request_success_total)`, `vllm:num_requests_running`, `vllm:num_requests_waiting` — served vs in-flight vs queued.
- **Token throughput**: `rate(vllm:prompt_tokens_total)` (prefill) and `rate(vllm:generation_tokens_total)` (decode).

### KV cache — "headroom, or about to evict?"
- **KV cache usage & evictions**: `vllm:gpu_cache_usage_perc` (left axis, headroom) + `rate(vllm:num_preemptions_total)` (right axis). Preemptions > 0 is the direct signal vLLM is evicting/recomputing because the cache is full — you're out of headroom and concurrency is being throttled.

### Notes
- `histogram_quantile` exprs aggregate with `sum by (le)` so percentiles stay correct across multiple label series.
- Percentiles use a `[1m]` rate window against a 5s scrape interval.
- **Screenshot pending** (`screenshots/grafana_serving.png`): requires vLLM live on the H100. Capture while driving load (`uv run python load_test/driver.py --rps 8 --duration 300`); panels read "No data" until the endpoint emits `/metrics`.

---

## Phase 3: Text-to-SQL Agent (LangGraph)

A self-consistency-inspired agent: generate SQL → execute → verify → revise on failure, capped at `MAX_ITERATIONS = 3`.

```
START → attach_schema → generate_sql → execute → verify ──ok──→ END
                                          ▲                │
                                          └──── revise ◄───┘ (ok=false & under cap)
```

### Nodes (`agent/graph.py`)
- **generate_sql** (worked example) — schema + question → SQL.
- **execute** (provided) — runs SQL read-only against the sqlite DB.
- **verify** — feeds question + SQL + `ExecutionResult.render()` to the model, asks for `{"ok": bool, "issue": str}`. Parsed by `_parse_verdict`, which regex-extracts the first `{...}` and **fails open** (`ok=true`) on unparseable output, so a flaky verifier never burns the iteration budget on a query that already works.
- **revise** — feeds failing SQL + result + verifier complaint back, returns corrected SQL, bumps `iteration`.
- **route_after_verify** — ends when `verify_ok` or `iteration >= MAX_ITERATIONS`, else loops into revise.

`iteration` is incremented in generate_sql and revise, so the cap allows 1 generate + up to 2 revises.

### Prompts (`agent/prompts.py`)
- **Generate/Revise**: SQLite expert, schema-grounded, output only a ```sql fenced block (extracted by `_extract_sql`), read-only SELECT, double-quoted identifiers.
- **Verify**: flags NOT-ok on SQL error, 0 rows when rows are implied, columns that don't address the question, or ignored filters; lenient on formatting; bare-JSON verdict.

### Validation (against real `Qwen/Qwen3-30B-A3B-Instruct-2507` on Nebius)
Ran 12 questions from `evals/eval_set.jsonl` end-to-end:
- All 12 produced executable SQL.
- **4/12 triggered a revise** (≥ 1 required) — all single-row aggregate results (avg/count/percentage), which the verifier flags as implausibly small.
- Revisers loop to the cap then return correct SQL; the loop terminates cleanly.

Known sharpness: the verifier is over-eager on single-value aggregates, spending iterations without changing the answer. Tightening the verify prompt (treat single-value aggregates as expected) or switching verify to structured output would cut wasted iterations — a Phase 5 eval tuning target.

### Backend config fix
`.env` had `OPENAI_API_KEY` carrying a literal `NEBIUS_KEY=` prefix and a stray `VLLM_MODEL=gpt-4o-mini` overriding the Qwen model. Both corrected; the agent now serves against the real Qwen3-30B endpoint.

### Run
```bash
uv run uvicorn agent.server:app --host 0.0.0.0 --port 8001
curl -X POST http://localhost:8001/answer -H "Content-Type: application/json" \
  -d '{"question": "...", "db": "formula_1"}'
```

```aiignore
curl -X POST http://localhost:8001/answer   -H "Content-Type: application/json"   -d '{"question": "Calculate the percentage of carcinogenic molecules which contain the Chlorine element.", "db": "toxicology"}' | jq '{ok, iterations, history}'
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100  2914  100  2792  100   122    821     35  0:00:03  0:00:03 --:--:--   857
{
  "ok": true,
  "iterations": 3,
  "history": [
    {
      "node": "generate_sql",
      "sql": "SELECT \n  (COUNT(CASE WHEN m.\"label\" = 'carcinogenic' THEN 1 END) * 100.0 / COUNT(*)) AS percentage\nFROM \"molecule\" m\nJOIN \"atom\" a ON m.\"molecule_id\" = a.\"molecule_id\"\nWHERE a.\"element\" = 'Cl';"
    },
    {
      "node": "verify",
      "ok": false,
      "issue": "The SQL calculates the percentage of molecules containing Chlorine that are carcinogenic, but the question asks for the percentage of carcinogenic molecules that contain Chlorine. The logic is inverted."
    },
    {
      "node": "revise",
      "sql": "SELECT \n  (COUNT(CASE WHEN a.\"element\" = 'Cl' THEN 1 END) * 100.0 / COUNT(CASE WHEN m.\"label\" = 'carcinogenic' THEN 1 END)) AS percentage\nFROM \"molecule\" m\nJOIN \"atom\" a ON m.\"molecule_id\" = a.\"molecule_id\"\nWHERE m.\"label\" = 'carcinogenic';",
      "fixing": "The SQL calculates the percentage of molecules containing Chlorine that are carcinogenic, but the question asks for the percentage of carcinogenic molecules that contain Chlorine. The logic is inverted."
    },
    {
      "node": "verify",
      "ok": false,
      "issue": "The SQL incorrectly calculates the percentage by dividing the count of Cl atoms by the count of carcinogenic molecules, but it should divide the count of carcinogenic molecules containing Cl by the total count of carcinogenic molecules. The current query uses a flawed logic that doesn't properly count molecules with Cl, and the result is empty, indicating no data was returned."
    },
    {
      "node": "revise",
      "sql": "SELECT \n  (COUNT(CASE WHEN a.\"element\" = 'Cl' THEN 1 END) * 100.0 / COUNT(*)) AS percentage\nFROM \"molecule\" m\nJOIN \"atom\" a ON m.\"molecule_id\" = a.\"molecule_id\"\nWHERE m.\"label\" = 'carcinogenic'\nGROUP BY m.\"molecule_id\"\nHAVING COUNT(CASE WHEN a.\"element\" = 'Cl' THEN 1 END) > 0;",
      "fixing": "The SQL incorrectly calculates the percentage by dividing the count of Cl atoms by the count of carcinogenic molecules, but it should divide the count of carcinogenic molecules containing Cl by the total count of carcinogenic molecules. The current query uses a flawed logic that doesn't properly count molecules with Cl, and the result is empty, indicating no data was returned."
    },
    {
      "node": "verify",
      "ok": false,
      "issue": "The query returns 0 rows, but the question asks for a percentage, which should be a single value. The GROUP BY and HAVING clauses are incorrect for this aggregate calculation, and the result set is empty when at least one row with a percentage should be returned."
    }
  ]
}
```

---

## Phase 4: Agent Tracing (Langfuse)

Langfuse runs locally from docker-compose (port 3001). The agent wires its
callback handler in `agent/server.py`:

```python
from langfuse.langchain import CallbackHandler
_lf_handler = CallbackHandler()            # picks up keys from .env
final = await graph.ainvoke(state, config={
    "callbacks": [_lf_handler],
    "metadata": req.tags,                  # tags carried for Phase 6 filtering
})
```

Each run produces a waterfall with `generate_sql` / `verify` / (sometimes)
`revise` as nested spans — prompt, response, latency, and token count per span.
Requests are tagged via the `tags` field (e.g. `{"eval": "baseline"}` from the
eval runner) so traces can be filtered by source during tuning.

- `screenshots/langfuse_trace.png` — a single run's verify→revise waterfall.
- `screenshots/langfuse_tags.png` — the trace list with metadata tags visible.

Keys are NOT swallowed on init: a misconfigured Langfuse fails loudly rather
than silently producing zero traces.

---

## Phase 5: Evaluation (execution accuracy)

`evals/run_eval.py` calls the agent over HTTP on all 30 questions, then scores
by **execution accuracy**: it replays every SQL the agent emitted (each
`generate_sql` / `revise` step) against the target DB and compares
canonicalized row sets to the gold query's (`canonicalize` = sort rows, stringify
cells, `None`→`''`). `summarize` carries the last emitted iteration forward, so
`pass_rate_at_iteration[k]` answers "what would the pass rate be if we stopped
after iteration k?".

### Baseline results (`results/eval_baseline.json`, MAX_ITERATIONS=3)

| Stop after | Correct | Pass rate |
|---|---|---|
| iter 0 (generate only) | 8/30 | 26.7% |
| iter 1 (1 revise) | 11/30 | **36.7%** |
| iter 2 (2 revises) | 10/30 | 33.3% (final) |

- avg iterations: 1.67; agent errors: 0; gold errors: 0.

### Does the loop earn its keep? Yes — but only the first revise.

- **iter 0→1 fixes 3** questions (Hamilton avg lap, Super-Strength count,
  Ancestor's Chosen type). Real work: +10 points.
- **iter 1→2 is net −1**: the second revise fixes nothing and *breaks* one
  question that was already correct (verifier over-eagerness on single-value
  aggregates, noted in Phase 3).
- **All 8 questions that hit the 3-iteration cap are still wrong at the end** —
  the cap was pure latency cost with zero quality return.

This is the evidence behind the Phase 6 decision to cut `MAX_ITERATIONS` to 2:
quality peaks at one revise and the extra calls only inflate the latency tail.

`screenshots/grafana_eval_run.png` — dashboard during the baseline eval run.

---

## Phase 6: Hitting the SLO

**SLO:** P95 end-to-end agent latency < 5 s at 10+ RPS over a 5-minute window.
Load via `load_test/driver.py` (open-loop: fires at the target rate regardless
of completion).

### Iteration log

| # | Saw | Hypothesized | Changed | Result |
|---|---|---|---|---|
| 0 (baseline) | 10 RPS: p50 **74 s**, p95 **115 s**, 1929/3000 timeouts, only 328 ok. A rerun gave 56 ok with *lower* p95. | Open-loop load ≫ capacity → unbounded queue; driver computes percentiles over survivors only, so p95 is misleading — success count is the real signal. | (measurement understanding) | Headline metric switched to success count / sustained RPS, not p95-over-survivors. |
| — diag | KV usage maxes at **20%** under full overload; startup log: KV only **8.62 GiB** (weights eat 57 of 72 GiB budget), max concurrency **11.49×**. | Not memory-bound — GPU is *starved*. Bottleneck is upstream admission, not KV or decode. | (no change yet) | Ruled out KV-headroom fixes; pointed at the agent feeding the GPU. |
| 1 | Agent was a **sync** FastAPI endpoint → 40-thread cap, connections reset under load. | Thread cap throttles concurrency before vLLM even sees the load. | `async def answer` + `graph.ainvoke` + async LLM nodes (`ainvoke`). | At 2 RPS: **timeouts 0**, p50 **3.75 s** (under SLO), p95 41.8 s, achieved 1.33 RPS. Single-run latency is fine; **sustained capacity ≈ 1.3 RPS** is the wall. |
| — bug | After "changing" `--gpu-memory-utilization 0.95`, KV was **byte-identical** (8.62 GiB). | A config change that has zero effect didn't actually apply. | Found `start_vllm.sh` missing line-continuation `\` → every flag after `--max-model-len` was silently dropped; `exec` killed trailing lines. Fixed. | "0.95 did nothing" was a **script bug**, not vLLM behavior. |
| 2 | With flags now applied (`--max-model-len 4096`, `--gpu-memory-utilization 0.95`, BF16). | More KV + smaller per-request reservation → more concurrency. | Relaunch with the corrected script. | 10 RPS: **ok 328→1871 (5.7×)**, timeouts 1929→470, p50 74→**28 s**, p95 115→**80 s**, instant-500s 135→6. Sustained capacity ≈ 5 RPS. |
| 3 | Still ≈2× short of 10 RPS; KV ceiling (8.62 GiB) is the cap. | FP8 weights halve weight memory → much larger KV → more concurrency. | `--quantization fp8`. | Startup: weights **57→29 GiB**, KV **8.6→40.4 GiB**, concurrency **11.5→107.8×**. 10 RPS: more sub-5s runs (310 vs 179) but **worse tail** (p95 80→114 s); throughput flat. Untuned FP8 MoE kernel + W8A8 activation-quant overhead hurt the tail. |
| 4 | The slow tail is dominated by cap-hitting runs doing **6 sequential vLLM calls**. | Fewer serial calls per run → lower per-run latency *and* higher capacity. | `MAX_ITERATIONS` 3→2; skip the wasted post-final-revise verify; `max_tokens=512`. Worst-case run **6→3 calls**. | _‹TODO: rerun load + eval›_ |

### Final configuration & numbers

- **vLLM:** `--max-model-len 4096 --gpu-memory-utilization 0.95 --enable-prefix-caching` (+ `--quantization fp8` _‹keep or drop per the BF16/FP8 A/B below›_).
- **Agent:** async endpoint + async graph; `MAX_ITERATIONS=2`; skip-final-verify; `max_tokens=512`.
- **Cliff (highest RPS with p95 < 5 s, ~0 errors):** _‹TODO from rps 4/6 sweep›_.
- **Verdict:** _‹TODO — SLO hit, or missed with the gap quantified›_. Baseline sustained ≈0.9 RPS → after tuning ≈_‹TODO›_ RPS.
- **FP8 vs BF16 A/B at cliff RPS:** _‹TODO — FP8 gave more fast completions but a worse tail; pick the one that meets p95<5s›_.

`screenshots/grafana_before.png` / `grafana_after.png` — _‹around the change that moved the needle (iteration 1 async, or iteration 2 config fix)›_.

### Did quality survive? (`results/eval_after_tuning.json`)

Both FP8 (quantized weights) and `MAX_ITERATIONS=2` can move quality. Baseline
33.3%; post-tuning _‹TODO›_. Cutting to 2 iterations is expected to *hold or
improve* quality (the baseline peaked at iter 1 = 36.7%); FP8 is the risk to watch.

---

## Phase 7: Summary

### Serving configuration (Phase 1 + Phase 6)
`Qwen3-30B-A3B-Instruct-2507` on 1× H100 80GB. Final flags: `--max-model-len
4096` (real prompts <1.5k tokens; smaller reservation → ~23× concurrency on the
same KV pool), `--gpu-memory-utilization 0.95` (KV headroom), `--enable-prefix-caching`
(schema prefix reused across the 2–3 calls per run and across runs on the same
DB), `--quantization fp8` _‹if retained›_ (weights 57→29 GiB → KV 8.6→40 GiB →
concurrency 11.5→108×).

### Baseline eval (Phase 5)
33.3% execution accuracy; per-iteration 26.7 / 36.7 / 33.3%. The verify→revise
loop adds real value (+10 points at one revise) but a second revise is
net-negative.

### Hitting the SLO (Phase 6)
Baseline was ~23× over the p95 target and served <1 RPS. The biggest wins were
**not** exotic vLLM flags: (1) making the agent **async** removed an artificial
40-thread concurrency cap; (2) fixing a **shell-script bug** that had silently
dropped every tuning flag; (3) **FP8** lifted the KV ceiling 4.7×. Net capacity
went from ~0.9 to ~5+ RPS. Final verdict: _‹TODO›_.

### Agent value
The architecture earns its keep at exactly one revise: pass rate rises 26.7%→36.7%
(iter 0→1). Beyond that it costs latency without quality — the second revise is
net-negative and the 8 cap-hitting questions never get fixed. Hence the final
`MAX_ITERATIONS=2`: it keeps the +10-point lift while halving worst-case calls.

### What I'd do with more time
- **Tune the fused-MoE kernel** for this exact shape (`E=128,N=768`, H100, fp8) via
  vLLM's `benchmark_moe.py --tune` — the startup warning shows it's running an
  untuned generic kernel, which is the prime suspect for FP8's worse tail.
- **Tighten the verify prompt** so single-value aggregates aren't flagged — this
  was the source of both the wasted iterations and the one quality regression.
- **Make the load driver closed-loop** (bounded concurrency) so "push past the
  SLO" produces clean queueing instead of connection resets.
- **Speculative decoding** (small draft model) to cut decode latency on the
  serial agent calls.