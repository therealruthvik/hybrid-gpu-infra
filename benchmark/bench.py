#!/usr/bin/env python3
"""
vLLM inference benchmark — measures tokens/sec, p50/p95 latency, GPU utilization.

Usage:
  # Basic (port-forward first: kubectl port-forward svc/vllm-mistral 8000:8000 -n gpu-workloads)
  python bench.py --url http://localhost:8000 --concurrency 4 --requests 50

  # With Prometheus GPU metrics
  python bench.py --url http://localhost:8000 --prometheus http://localhost:9090 \
    --concurrency 8 --requests 100 --output results.md
"""

import argparse
import asyncio
import time
import statistics
import json
import sys
from dataclasses import dataclass, field
from typing import Optional

import aiohttp


PROMPT_TEMPLATE = (
    "Explain the concept of {topic} in exactly 200 words. Be precise and technical."
)
TOPICS = [
    "quantum entanglement",
    "transformer attention mechanisms",
    "gradient descent optimization",
    "Byzantine fault tolerance",
    "consistent hashing",
    "CUDA memory coalescing",
    "tensor parallelism in LLMs",
    "speculative decoding",
    "KV cache eviction policies",
    "flash attention algorithm",
]


@dataclass
class RequestResult:
    prompt_tokens: int
    completion_tokens: int
    total_latency_s: float
    success: bool
    error: str = ""


@dataclass
class BenchmarkResults:
    concurrency: int
    total_requests: int
    successful: int = 0
    failed: int = 0
    latencies: list[float] = field(default_factory=list)
    total_tokens_generated: int = 0
    wall_time_s: float = 0.0
    gpu_util_pct: Optional[float] = None
    gpu_mem_used_mb: Optional[float] = None

    @property
    def throughput_tps(self) -> float:
        if self.wall_time_s == 0:
            return 0
        return self.total_tokens_generated / self.wall_time_s

    @property
    def p50_latency(self) -> float:
        return statistics.median(self.latencies) if self.latencies else 0

    @property
    def p95_latency(self) -> float:
        if not self.latencies:
            return 0
        idx = int(len(self.latencies) * 0.95)
        return sorted(self.latencies)[idx]

    @property
    def success_rate(self) -> float:
        return self.successful / self.total_requests if self.total_requests else 0


async def send_request(
    session: aiohttp.ClientSession,
    url: str,
    prompt: str,
    model: str,
    max_tokens: int = 256,
) -> RequestResult:
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.0,
    }
    t0 = time.perf_counter()
    try:
        async with session.post(
            f"{url}/v1/chat/completions",
            json=payload,
            timeout=aiohttp.ClientTimeout(total=120),
        ) as resp:
            data = await resp.json()
            latency = time.perf_counter() - t0
            if resp.status != 200:
                return RequestResult(0, 0, latency, False, str(data))
            usage = data.get("usage", {})
            return RequestResult(
                prompt_tokens=usage.get("prompt_tokens", 0),
                completion_tokens=usage.get("completion_tokens", 0),
                total_latency_s=latency,
                success=True,
            )
    except Exception as exc:
        return RequestResult(0, 0, time.perf_counter() - t0, False, str(exc))


async def get_gpu_metrics(prometheus_url: str) -> dict:
    """Query Prometheus for current GPU utilization and memory."""
    queries = {
        "gpu_util": "avg(DCGM_FI_DEV_GPU_UTIL)",
        "gpu_mem_used": "avg(DCGM_FI_DEV_FB_USED)",
    }
    results = {}
    async with aiohttp.ClientSession() as session:
        for key, query in queries.items():
            try:
                async with session.get(
                    f"{prometheus_url}/api/v1/query",
                    params={"query": query},
                    timeout=aiohttp.ClientTimeout(total=5),
                ) as resp:
                    data = await resp.json()
                    result = data["data"]["result"]
                    if result:
                        results[key] = float(result[0]["value"][1])
            except Exception:
                pass
    return results


async def run_benchmark(args: argparse.Namespace) -> BenchmarkResults:
    results = BenchmarkResults(
        concurrency=args.concurrency,
        total_requests=args.requests,
    )

    # Discover model name from /v1/models
    async with aiohttp.ClientSession() as session:
        try:
            async with session.get(
                f"{args.url}/v1/models",
                timeout=aiohttp.ClientTimeout(total=10),
            ) as resp:
                data = await resp.json()
                model = data["data"][0]["id"]
                print(f"Model: {model}")
        except Exception as exc:
            print(f"Could not fetch model list: {exc}. Using 'default'.")
            model = "default"

    semaphore = asyncio.Semaphore(args.concurrency)
    prompts = [
        PROMPT_TEMPLATE.format(topic=TOPICS[i % len(TOPICS)])
        for i in range(args.requests)
    ]

    async def bounded_request(prompt: str) -> RequestResult:
        async with semaphore:
            async with aiohttp.ClientSession() as session:
                return await send_request(session, args.url, prompt, model)

    print(f"Sending {args.requests} requests at concurrency={args.concurrency}...")
    t_start = time.perf_counter()
    tasks = [asyncio.create_task(bounded_request(p)) for p in prompts]

    completed = 0
    for coro in asyncio.as_completed(tasks):
        r = await coro
        completed += 1
        if r.success:
            results.successful += 1
            results.latencies.append(r.total_latency_s)
            results.total_tokens_generated += r.completion_tokens
        else:
            results.failed += 1
            if args.verbose:
                print(f"  FAIL: {r.error[:80]}")
        if completed % 10 == 0:
            print(f"  {completed}/{args.requests} done...")

    results.wall_time_s = time.perf_counter() - t_start

    # Sample GPU metrics at end of run
    if args.prometheus:
        gpu_data = await get_gpu_metrics(args.prometheus)
        results.gpu_util_pct = gpu_data.get("gpu_util")
        results.gpu_mem_used_mb = gpu_data.get("gpu_mem_used")

    return results


def render_markdown(r: BenchmarkResults, url: str, model_hint: str) -> str:
    lines = [
        "# vLLM Inference Benchmark Results",
        "",
        f"**Endpoint:** `{url}`",
        f"**Model:** `{model_hint}`",
        f"**Date:** {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}",
        "",
        "## Summary",
        "",
        "| Metric | Value |",
        "|--------|-------|",
        f"| Total Requests | {r.total_requests} |",
        f"| Successful | {r.successful} ({r.success_rate:.1%}) |",
        f"| Failed | {r.failed} |",
        f"| Concurrency | {r.concurrency} |",
        f"| Wall Time | {r.wall_time_s:.2f}s |",
        "",
        "## Throughput & Latency",
        "",
        "| Metric | Value |",
        "|--------|-------|",
        f"| Tokens/sec (output) | **{r.throughput_tps:.1f}** |",
        f"| p50 Latency | **{r.p50_latency:.3f}s** |",
        f"| p95 Latency | **{r.p95_latency:.3f}s** |",
        f"| Min Latency | {min(r.latencies):.3f}s |" if r.latencies else "",
        f"| Max Latency | {max(r.latencies):.3f}s |" if r.latencies else "",
        "",
    ]
    if r.gpu_util_pct is not None or r.gpu_mem_used_mb is not None:
        lines += [
            "## GPU Metrics (sampled at end of run)",
            "",
            "| Metric | Value |",
            "|--------|-------|",
        ]
        if r.gpu_util_pct is not None:
            lines.append(f"| GPU Utilization | {r.gpu_util_pct:.1f}% |")
        if r.gpu_mem_used_mb is not None:
            lines.append(f"| GPU Memory Used | {r.gpu_mem_used_mb:.0f} MiB |")
        lines.append("")

    return "\n".join(l for l in lines if l is not None)


def main():
    parser = argparse.ArgumentParser(description="vLLM inference benchmark")
    parser.add_argument("--url", default="http://localhost:8000", help="vLLM base URL")
    parser.add_argument("--concurrency", type=int, default=4, help="Concurrent requests")
    parser.add_argument("--requests", type=int, default=50, help="Total requests")
    parser.add_argument("--max-tokens", type=int, default=256, help="Max output tokens")
    parser.add_argument("--prometheus", default=None, help="Prometheus URL for GPU metrics")
    parser.add_argument("--output", default=None, help="Write markdown results to file")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    results = asyncio.run(run_benchmark(args))

    print(f"\n{'='*50}")
    print(f"Throughput:    {results.throughput_tps:.1f} tokens/sec")
    print(f"p50 latency:   {results.p50_latency:.3f}s")
    print(f"p95 latency:   {results.p95_latency:.3f}s")
    print(f"Success rate:  {results.success_rate:.1%}")
    if results.gpu_util_pct:
        print(f"GPU util:      {results.gpu_util_pct:.1f}%")
    print(f"{'='*50}\n")

    md = render_markdown(results, args.url, "mistral-7b-awq")
    if args.output:
        with open(args.output, "w") as f:
            f.write(md)
        print(f"Results written to {args.output}")
    else:
        print(md)


if __name__ == "__main__":
    main()
