# vLLM Inference Benchmark Results

**Endpoint:** `http://localhost:8000`
**Model:** `mistral-7b-awq` (TheBloke/Mistral-7B-Instruct-v0.1-AWQ)
**Hardware:** Lambda Labs A10 (24 GB VRAM)
**Date:** 2025-08-01 14:22:10 UTC

## Summary

| Metric | Value |
|--------|-------|
| Total Requests | 100 |
| Successful | 100 (100.0%) |
| Failed | 0 |
| Concurrency | 8 |
| Wall Time | 87.34s |

## Throughput & Latency

| Metric | Value |
|--------|-------|
| Tokens/sec (output) | **232.7** |
| p50 Latency | **3.412s** |
| p95 Latency | **8.901s** |
| Min Latency | 1.234s |
| Max Latency | 12.103s |

## GPU Metrics (sampled at end of run)

| Metric | Value |
|--------|-------|
| GPU Utilization | 87.4% |
| GPU Memory Used | 19840 MiB |

## Notes

- AWQ quantization fits comfortably in 24 GB with `--gpu-memory-utilization 0.85`
- p95 latency spikes under concurrency=8 due to KV-cache pressure at ~200 token output length
- Recommend `--max-model-len 2048` if primarily short-context workloads — reduces memory pressure, improves p95

## Concurrency Sweep

| Concurrency | Tokens/sec | p50 (s) | p95 (s) | GPU Util % |
|-------------|-----------|---------|---------|------------|
| 1           | 52.1      | 1.87    | 2.10    | 41%        |
| 2           | 98.3      | 1.95    | 2.88    | 67%        |
| 4           | 167.4     | 2.43    | 4.21    | 81%        |
| 8           | 232.7     | 3.41    | 8.90    | 87%        |
| 16          | 241.2     | 6.88    | 18.44   | 89%        |

**Optimal concurrency:** 8 — best throughput/latency tradeoff for ~200 token outputs.
