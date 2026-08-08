#!/usr/bin/env python3
"""Benchmark a running llama-server the way an agent actually uses it.

Point it at a server that's already up (`--url`), pick a scenario, read the
table. Standard library only.

    ./agentic-bench.py --scenario turns
    ./agentic-bench.py --scenario prefill --sizes 2000,16000,64000
    ./agentic-bench.py --scenario depth --sizes 2000,32000,96000

Why these three:

  turns    An agent loop re-sends a growing prefix every turn (persona +
           memory + tool defs + history), so llama.cpp's prompt cache means
           only the delta is prefilled. This is the number that decides how
           the agent *feels*, and it's usually far better than a cold
           prefill measurement suggests. Reported per turn.
  prefill  Cold prefill with the cache off — the worst case you hit when a
           conversation starts fresh or the cache is evicted.
  depth    Generation speed as context fills. Sparse-attention models hold
           flat here; most don't.

Timings come from llama-server's own `timings` object, so they exclude
client overhead. `prompt_ms` is the prefill cost and the best available
proxy for time-to-first-token.
"""

import argparse
import json
import urllib.error
import urllib.request

# Roughly one token per word for these filler words, which is close enough
# for sizing prompts. Don't read the token counts off this — read them off
# the server's `prompt_n`.
FILLER = "the quick brown fox jumps over a lazy dog while parsing tokens "


def words(n: int) -> str:
    reps = n // len(FILLER.split()) + 1
    return " ".join((FILLER * reps).split()[:n])


def complete(url: str, prompt: str, n_predict: int, cache: bool, timeout: int):
    """POST /completion and return the server's timings, or None on failure."""
    body = json.dumps(
        {
            "prompt": prompt,
            "n_predict": n_predict,
            "temperature": 0,
            "cache_prompt": cache,
        }
    ).encode()
    req = urllib.request.Request(
        f"{url}/completion", data=body, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp).get("timings")
    except urllib.error.URLError as e:
        # A long cold prefill can exceed the timeout — that's a result, not a
        # crash. Report it and let the caller keep going.
        print(f"  request failed ({e}); raise --timeout if this was a long prefill")
        return None


def row(label, t):
    if not t:
        return
    pp = t["prompt_per_second"]
    tg = t["predicted_per_second"]
    print(
        f"{label:<22} ctx={t['prompt_n']:>7}  prefill={t['prompt_ms'] / 1000:>7.1f}s "
        f"({pp:>7.1f} tok/s)  gen={tg:>6.2f} tok/s"
    )


def scenario_turns(url, system_tokens, turns, reply_tokens, timeout):
    """Simulate an agent loop: fixed prefix, one tool result appended per turn."""
    print(f"agent loop: {system_tokens}-token prefix, {turns} turns, prompt cache ON\n")
    prefix = "SYSTEM: " + words(system_tokens) + "\n"
    convo = prefix
    for i in range(1, turns + 1):
        convo += f"\nTOOL_RESULT[{i}]: " + words(400) + "\nASSISTANT:"
        t = complete(url, convo, reply_tokens, True, timeout)
        row(f"turn {i}", t)
        if t:
            # Feed the reply back in so the next turn's prefix genuinely grows.
            convo += " " + words(reply_tokens)
    print(
        "\nPrefill tok/s climbs across turns because the cache covers the "
        "shared prefix; the per-turn prefill *seconds* are what the agent waits."
    )


def scenario_prefill(url, sizes, timeout):
    print("cold prefill, prompt cache OFF\n")
    for n in sizes:
        row(f"prompt {n}", complete(url, words(n), 8, False, timeout))


def scenario_depth(url, sizes, timeout):
    print("generation speed at depth, prompt cache OFF\n")
    for n in sizes:
        row(f"depth {n}", complete(url, words(n), 64, False, timeout))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--url", default="http://127.0.0.1:8080")
    p.add_argument("--scenario", choices=["turns", "prefill", "depth"], default="turns")
    p.add_argument("--sizes", default="2000,16000,64000", help="comma-separated prompt sizes")
    p.add_argument("--system-tokens", type=int, default=8000)
    p.add_argument("--turns", type=int, default=5)
    p.add_argument("--reply-tokens", type=int, default=200)
    p.add_argument("--timeout", type=int, default=1800)
    a = p.parse_args()

    # Warm the model and the page cache. A first-run number is always wrong:
    # a cold GGUF read measured 1.5 tok/s where warm was 2.9.
    print("warming up (discarding first run)...")
    complete(a.url, words(200), 8, False, a.timeout)

    if a.scenario == "turns":
        scenario_turns(a.url, a.system_tokens, a.turns, a.reply_tokens, a.timeout)
    else:
        sizes = [int(s) for s in a.sizes.split(",")]
        (scenario_prefill if a.scenario == "prefill" else scenario_depth)(a.url, sizes, a.timeout)


if __name__ == "__main__":
    main()
