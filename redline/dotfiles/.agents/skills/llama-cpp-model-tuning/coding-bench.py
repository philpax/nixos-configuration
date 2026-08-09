#!/usr/bin/env python3
# ruff: noqa: E501
"""Benchmark a running llama-server with realistic coding-agent prompts.

Unlike agentic-bench.py which uses repetitive filler text, this sends actual
coding prompts (system + tool defs + user requests) to measure realistic
acceptance rates for speculative decoding and realistic generation speed.

    ./coding-bench.py --url http://127.0.0.1:8080
    ./coding-bench.py --url http://127.0.0.1:8080 --turns 8

Standard library only.
"""

import argparse
import json
import urllib.error
import urllib.request

# Realistic coding-agent system prompt with tool definitions
SYSTEM = """You are an expert software engineer. You have access to the following tools:

- read_file(path: str) -> str: Read the contents of a file.
- write_file(path: str, content: str) -> None: Write content to a file.
- run_command(cmd: str) -> str: Run a shell command and return stdout.
- search(query: str) -> str: Search the codebase for a pattern.

When you need to use a tool, format your response as a JSON object with "tool" and "args" keys.
Always explain your reasoning before taking action. Consider edge cases, error handling, and performance implications."""

# Realistic coding prompts that produce non-repetitive output
PROMPTS = [
    "Write a Rust function that takes a Vec<PathBuf> and returns a HashMap<String, Vec<PathBuf>> grouping files by their extension. Handle edge cases like files with no extension, hidden files, and non-UTF8 paths. Use thiserror for error types.",
    "Refactor this Python class to use async/await instead of threading. The class manages a pool of worker connections and needs to handle timeouts gracefully: class WorkerPool: def __init__(self, size): self.workers = [Worker() for _ in range(size)] def submit(self, task): # ...",
    "Implement a TypeScript debounce function that supports cancellation and immediate execution. It should be generic over the function signature and properly handle 'this' binding. Include JSDoc comments.",
    "Write a SQL query to find the top 10 customers by total revenue in the last 30 days, including their email and last purchase date. Handle customers with no purchases. The schema has tables: customers(id, email, name), orders(id, customer_id, total, created_at).",
    "Debug this Go code — it deadlocks occasionally. The worker pool processes jobs from a channel but sometimes hangs on shutdown: func process(jobs <-chan Job) { for j := range jobs { handle(j) } }",
    "Write a Nix module that defines a systemd service running a Python script. The service should have a configurable package, environment variables, and a health check. Include an option for the listen port.",
    "Implement a C function that parses a simple HTTP request line (GET /path HTTP/1.1) without using strtok. Handle edge cases: leading whitespace, extra spaces, missing version. Return a struct with method, path, and version.",
    "Write a Dockerfile for a multi-stage build of a Rust application. The first stage builds with cargo, the second creates a minimal runtime image with only the binary and necessary certs. Use distroless as the final base.",
]


def complete(url, messages, n_predict, model="laguna", temperature=0.7, timeout=180):
    """POST /v1/chat/completions and return the server's timings."""
    body = json.dumps(
        {
            "model": model,
            "messages": messages,
            "max_tokens": n_predict,
            "temperature": temperature,
        }
    ).encode()
    req = urllib.request.Request(
        f"{url}/v1/chat/completions", data=body, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp)
    except urllib.error.URLError as e:
        print(f"  request failed ({e})")
        return None


def run_single_prompts(url, timeout, model):
    """Send individual coding prompts and measure generation speed."""
    print("realistic coding prompts (single-turn)\n")
    for i, prompt in enumerate(PROMPTS):
        messages = [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": prompt},
        ]
        result = complete(url, messages, 200, model=model, timeout=timeout)
        if result:
            t = result.get("timings", {})
            content = result["choices"][0]["message"]["content"][:80]
            print(
                f"  prompt {i + 1:<2} gen={t.get('predicted_per_second', 0):>6.2f} tok/s  "
                f"prefill={t.get('prompt_per_second', 0):>7.1f} tok/s  "
                f"tokens={t.get('predicted_n', 0):>4}  "
                f"output: {content}..."
            )


def run_agent_turns(url, turns, timeout, model):
    """Simulate a multi-turn coding agent loop with growing context."""
    print(f"agent loop: {len(SYSTEM)}-token system+tools, {turns} turns\n")
    messages = [
        {"role": "system", "content": SYSTEM},
    ]
    for i in range(turns):
        messages.append({"role": "user", "content": PROMPTS[i % len(PROMPTS)]})
        result = complete(url, messages, 200, model=model, timeout=timeout)
        if result:
            t = result.get("timings", {})
            print(
                f"  turn {i + 1:<2} gen={t.get('predicted_per_second', 0):>6.2f} tok/s  "
                f"prefill={t.get('prompt_per_second', 0):>7.1f} tok/s  "
                f"prompt_n={t.get('prompt_n', 0):>5}  "
                f"prefill_s={t.get('prompt_ms', 0) / 1000:.1f}s"
            )
            # Feed a realistic assistant reply back in
            messages.append(
                {"role": "assistant", "content": result["choices"][0]["message"]["content"]}
            )
        else:
            break


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--url", default="http://127.0.0.1:8080")
    p.add_argument(
        "--turns", type=int, default=0, help="run multi-turn agent loop instead of single prompts"
    )
    p.add_argument("--timeout", type=int, default=300)
    p.add_argument(
        "--model",
        default="laguna",
        help="model name sent in the request body — must match the service name when going "
        "through the OpenAI multiplexer (port 7070); ignored by the raw per-service proxy",
    )
    a = p.parse_args()

    print("warming up...")
    complete(a.url, [{"role": "user", "content": "Hello"}], 8, model=a.model, timeout=a.timeout)

    if a.turns > 0:
        run_agent_turns(a.url, a.turns, a.timeout, a.model)
    else:
        run_single_prompts(a.url, a.timeout, a.model)


if __name__ == "__main__":
    main()
