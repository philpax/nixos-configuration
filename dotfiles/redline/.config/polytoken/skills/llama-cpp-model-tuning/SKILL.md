---
description: Use when adding a GGUF model to an ananke/llama.cpp setup, or tuning one that doesn't fit in VRAM. Triggers on "add this model to ananke", "dial in this model", "what config for X", or a model too large for the GPUs that needs hybrid CPU offload.
---

# Adding a model to an ananke + llama.cpp setup

Two questions decide how much work this is: does ananke (the model-serving daemon; see *Vocabulary*) already know the architecture, and does the model fit in VRAM? Usually both answers are yes, and you're done in ten minutes without benchmarking anything.

## Parameters — adapt these to your setup

This skill was written for one deployment. Everything below is a local value; substitute yours, and the rest of the skill follows. If you run a non-NixOS host or a different serving layout, the *Deploy* and *Paths* rows are the ones that change most.

**Machine.** Two RTX 3090s (24 GiB each, 48 GiB total, SM 8.6), a Threadripper 3960X (24 physical cores, 48 threads, multi-CCD), 256 GiB RAM. Every performance number and hardware aside below is relative to this box.

**Paths.**

| what | value |
|---|---|
| ananke source (and `dump-gguf`/`estimate` examples) | `/mnt/ssd0/ai/ananke` |
| model files (GGUFs, `bench/` dirs) | `/mnt/ssd0/ai/llm` |
| the model list config | `~/nixos-configuration/nixos/redline/ai/ananke.nix` |
| llama.cpp flake pin | `~/nixos-configuration/nixos/redline/ai/llama-flake/flake.nix` |
| llama.cpp source checkout | `~/programming/llama.cpp` |
| ik_llama.cpp flake pin | `~/nixos-configuration/nixos/redline/ai/ik-llama-flake/flake.nix` |
| ik_llama.cpp source checkout | `~/programming/ik_llama.cpp` |

Both llama-server binaries are on `PATH`: mainline as `llama-server`, the fork (ikawrakow's ik_llama.cpp) as `ik-llama-server` — prefixed so the names don't collide. See *Serving with ik_llama.cpp*.

**Ports.** OpenAI-compatible API on **7070**; management API + dashboard on **7071**; each service also gets a raw llama-server reverse proxy on **8200 + its index** in the model list.

**Deploy (NixOS-specific).** Build ananke with `cargo build` in its source dir — a *debug* build, because the systemd unit runs `target/debug/ananke` and `--release` would do nothing. Apply config with `sudo nixos-rebuild switch`, restart with `sudo systemctl restart ananke`, drive with the `anankectl` CLI. A non-Nix deployment substitutes its own build/deploy/restart path here.

**Integrations.** `discordVisible` is a bespoke helper (yours may differ or be absent) — see *Vocabulary*.

**The performance numbers here come from two models.** The mainline-hybrid reference is DeepSeek-V4-Flash (UD-IQ3_XXS, ~96 GiB on disk, 256 experts with 6 active, most experts on CPU) at ~3 tok/s. The ik_llama.cpp reference is GLM-5.2 (`glm-dsa`, 744B-A40B, muzzy smol-IQ2_KS, ~205 GiB) at ~8 tok/s flat to 58k+ depth — larger on disk yet more than twice as fast, because the fork's CPU kernels and DSA sparse attention change the shape entirely. Both ran on the *Machine* above.

They illustrate *shape*, not targets. A dense 27B that fits on one card behaves like neither — its speed is bounded by GPU memory bandwidth, not a CPU-resident expert stack.

## Vocabulary

- **ananke** — the daemon that owns model serving. It supervises `llama-server` (and vLLM) child processes, estimates each model's VRAM, packs models onto GPUs, evicts them under pressure, and fronts everything with an OpenAI-compatible API. Ports, source path, and the `anankectl` CLI are in *Parameters*.
- **estimator** — ananke's per-architecture VRAM model: weights, KV per token, compute buffer. Lives in `ananke/src/estimator/`. It's what rejects an unknown architecture.
- **packer** (allocator) — decides placement given the estimate: which layers land on which GPU, which experts spill to CPU, and it synthesises the `-ot` rules. Lives in `ananke/src/allocator/`. The estimator predicts; the packer places.
- **operator** — the human running the box. When something is a judgement call about use case, it's theirs.
- **ik_llama.cpp** — ikawrakow's fork of llama.cpp, with CPU-optimised kernels for i-quants and its own feature set (DSA sparse attention, MTP, `--fit`). ananke serves it as a first-class runtime via `runtime = { kind = "ik-llama"; … }`. Reach for it when a hybrid i-quant is CPU-dequant-bound — see *Serving with ik_llama.cpp*.

Config nouns, all set in your `ananke.nix` (path in *Parameters*):

- **`models`** — the list that generates ananke's service config. Each entry has `name`, `file` (relative to the model dir), optionally `mmproj` (a vision projector, sits *beside* `extras`, not inside it), and `extras`.
- **`extras`** — an attrset merged verbatim into the generated service. Keys must match ananke's schema exactly: the parser uses `deny_unknown_fields`, so a typo or a llama.cpp flag name is a hard config error, not a silent no-op.
- **`discordVisible`** — a bespoke helper (your deployment may lack it) setting `metadata.discord_visible`, which paxcord's `/askchorus` filters on. Only add it for models you want in the Discord rotation. It's shallow-merged, so an entry needing other metadata must write the whole table inline.

## Read the model first

ananke has both tools. Don't hand-roll a GGUF parser or the fit arithmetic:

```
cd /mnt/ssd0/ai/ananke
cargo run --example dump-gguf -- /mnt/ssd0/ai/llm/<path>/<first-shard>.gguf
cargo run --example estimate  -- --model <same path> --context 32768 --active-devices 1
```

`dump-gguf` prints the architecture, block count, shards, total size, the per-layer expert/non-expert split, and the metadata keys the estimator needs. `estimate` gives weights, KV per token, compute buffer, and a `gpu_vram_mib` total — that's your fit answer. Note its compute buffer is per device and it doubles for a 2-GPU split, so pass `--active-devices 1` when comparing against one card.

## Pick your job

**Architecture known, model fits.** Add it to the list. No benchmarking — there's nothing to tune.

**Architecture known, doesn't fit at the context you want.** See "making it fit".

**Architecture unknown to ananke.** Separate, larger job — see "adding an architecture" — then come back.

To check support, look for the arch in a family constant:

```
grep -rn '"<arch>"' /mnt/ssd0/ai/ananke/ananke/src/estimator/*.rs | grep -v test
```

The hit you want is inside a `*_FAMILY` array (e.g. `moe.rs`). A match arm in `compute_buffer.rs` is only a tuning curve — it doesn't mean the arch is supported. With no hit, the service stays disabled with `UnknownArchitecture`, unless the operator sets `estimation.allow_fallback = true` for a coarse weights-only estimate. That's a legitimate stopgap when you want the model running before the estimator work lands, but it does no KV modelling, so placement will be crude.

## Adding a model

Add an entry to `models`, in its family group — the `# <Name> family.` comment blocks that divide the list. A minimal entry is just `name` and `file` (the path under the model dir); `extras` holds everything else and can be left off.

```nix
{
  name = "some-model-27b";
  file = "unsloth/Some-Model-27B-GGUF/Some-Model-27B-UD-Q4_K_XL.gguf";
  extras = { context = 8192; };
}
```

Set `context` to what the use case needs. Its native maximum is ideal if that fits — re-run `estimate` at that context to confirm — but most existing entries sit at 8192, well below native, because that's what they need. If your target context doesn't fit, see *Making it fit*. Follow the model author's published sampling recommendation rather than habit.

Deploy it — the build and apply commands are in *Parameters* (note: debug build, because the systemd unit runs `target/debug/ananke`):

```
cd /mnt/ssd0/ai/ananke && cargo build
sudo nixos-rebuild switch
sudo systemctl restart ananke
anankectl start <name>     # or just send it a request via 7070; services are on-demand
```

A config that parses isn't a config that runs. Load it once and watch it come up (`anankectl logs <name>`).

## Config keys, not CLI flags

ananke owns the llama-server command line. Set knobs as config keys; raw flags only reach the child through `extra_args`, which bypasses the estimator's knowledge of them.

| llama.cpp | ananke key |
|---|---|
| `-c` | `context` |
| `-t` | `threads` |
| `-b` / `-ub` | `batch_size` / `ubatch_size` |
| `-np` | `parallel` |
| `--kv-unified` | `kv_unified = true` (enabled by default if `parallel` is auto) |
| `-fa` | `flash_attn = true` |
| `--cache-type-k/v` | `cache_type_k` / `cache_type_v` |
| `--numa distribute` | `numa = "distribute"` |
| `--split-mode row\|tensor` | `devices.split = "row"\|"tensor"` |
| `-ot` | `override_tensor` (list of rules) |
| `--cpu-moe` / `--n-cpu-moe` | **`expert_offload`** — see below |
| ik_llama.cpp + its `-mla`/`-dsa`/`--fit`/`-amb`/`-rtr` | `runtime = { kind = "ik-llama"; … }` — see *Serving with ik_llama.cpp* |
| anything else | `extra_args = [ "--flag" "value" ]` |

`expert_offload` is the coarse MoE fit knob: `"off"` (default), `"auto"` (the packer fills VRAM with expert layers from the estimate and offloads the rest), or an integer layer count. **There is no `n_cpu_moe` key** — writing one is a hard config error. `"auto"` depends on the estimator understanding the architecture; without that it under-reserves and OOMs at load.

`parallel` defaults to auto (4 slots), which allocates 4 separate KV caches. For single-user setups, set `parallel = 1` to free VRAM for more context. For concurrency, use `parallel = N` with `kv_unified = true` — slots share one context-sized KV pool, so the cost is nearly free. Cap generation length (`-n`) when using `kv_unified`: uncapped runaway generations exhaust the shared pool and trigger an assertion (see the gemma-4-31b-it-qat entry for the pattern).

## Making it fit

When the model won't fit at the context you want, the operator chooses what to sacrifice. Don't pick silently — the tradeoffs aren't equivalent. Offer them roughly in this order:

1. **Quantised KV** (`cache_type_k`/`cache_type_v = "q8_0"`, needs `flash_attn`). Small quality cost, often halves KV.
2. **Less context.** Free, if the use case doesn't need the full window.
3. **A smaller quant.** A Q4 that fits entirely on GPU beats a Q5 that spills to CPU, by a wide margin.
4. **CPU offload (hybrid).** Last resort, and a cliff rather than a slope: DeepSeek-V4-Flash ran ~3 tok/s hybrid on mainline. But if the quant is an i-quant (`IQ*`), don't accept a mainline hybrid number before trying **ik_llama.cpp** (below) — its CPU kernels routinely multiply hybrid generation several-fold, because the wall is usually CPU dequant, not RAM bandwidth.

Options 3 and 4 both interact with the runtime: a smaller *ik-native* quant served through ik_llama.cpp can beat a larger mainline quant on both speed and quality at once. Only these two pull in the next two sections.

## Hybrid tuning (CPU offload only)

Skip this entirely unless the weights can't all live on the GPUs.

**Test placement before writing the ananke entry.** Drive `llama-server` / `ik-llama-server` directly with `--fit` (both forks ship it) to auto-discover the optimal per-tensor placement. This is faster and usually better than hand-tuning `-cmoe`/`-ncmoe`/`-ot` — on Laguna S 2.1, `--fit on` was 50% faster than the best manual `-cmoe` placement because it distributes individual expert tensors across cards rather than whole layers. Once you've found the config that works, translate it to ananke keys: `devices.placement = "hybrid"` + `expert_offload = "auto"` should reproduce the same placement once the estimator knows the architecture.

ik_llama's `--fit` needs an explicit margin (`--fit-margin N`, in MiB) because it accounts only weights + KV, not compute buffers. Budget ~4 GiB/card for ub2048 prefill scratch. An unmargined `--fit` loads clean then OOMs on the first request — the same deferred failure as *The `--fit` margin trap* below.

Start with `devices = { placement = "hybrid"; }` and `expert_offload = "auto"`. That's the whole config for the common case — the packer balances experts across both cards and synthesises the `-ot` rules. The DeepSeek-V4-Flash entry is exactly this plus `threads`, `numa`, and batch sizes.

Reach for a hand-written `override_tensor` only when you need to pin an exact placement the packer won't produce. Two things that *used* to be required and no longer are: ananke comma-joins all `override_tensor` elements into a single `-ot` flag, so you don't need to pack them into one string; and the packer balances expert placement across cards itself, so you don't need to hand-alternate `blk\.N\.…=CUDA0,CUDA1`. The underlying llama.cpp facts still hold — repeated `-ot` flags are last-wins, and `--split-mode layer` assigns contiguous layer ranges — so keep them in mind when reading a raw command line or debugging a placement.

Useful knobs beyond the defaults: `threads` (physical cores, 24 on the *Machine* — SMT didn't help generation), `numa = "distribute"` (free prefill win on the 3960X's multi-CCD layout, 67 → 88 tok/s, no change to generation), and `ubatch_size`, which drives prefill speed *and* compute-buffer size and is therefore the knob that trades context against prefill.

Find the knee, then stop. Moving expert layers onto the GPU bought about +0.7 tok/s and then flattened — the ceiling was unoptimised attention kernels in a new architecture, not the CPU experts everyone blames. Past the knee, extra GPU capacity buys nothing; spend it on context or give a card back.

## Serving with ik_llama.cpp

When a hybrid MoE's generation ceiling is **CPU dequant compute, not RAM bandwidth**, ik_llama.cpp (ikawrakow's fork) is the biggest lever available — bigger than any placement tweak. i-quants (`IQ1_*`, `IQ2_XXS`, …) encode weights with per-group codebook lookups that mainline's CPU path handles slowly, and the fork exists to make exactly that fast.

It also ships features mainline lacked at our pin: DSA sparse attention, MTP speculative decoding, `-sm graph`, and `--fit` auto-placement.

**Is it your case?** Multiply expert bytes read per token by tok/s to get effective GB/s, and compare to the box's memory bandwidth. Far below it → dequant-bound, and ik helps a lot. Near it → bandwidth-bound, and ik won't. (GLM-5.2 at 1 tok/s on mainline was reading ~6 GB/s against ~70 available — squarely dequant-bound.)

**Pick an ik-native quant.** The muzzy, sokann, and ubergarm HF repos publish quants built for the fork — `IQ2_KS`, `IQ2_KT`, `IQ2_KL`, the `IQ*_KT` trellis family — which dequant faster on CPU than the equivalent mainline i-quant and are often smaller at equal perplexity. `KS` dequants faster than `KT` (speed over quality); `KT` is smaller at equal quality. ananke's GGUF reader knows these dtypes (ggml ids 133–158) and the estimator sizes `glm-dsa`, so `dump-gguf`/`estimate` work on them unchanged.

**Config.** Point `llama_server` at `ik-llama-server` and add the tagged runtime table; fork-only knobs live inside it. The GLM-5.2 reference entry:

```nix
{
  name = "glm-5.2";
  file = "muzzy/GLM-5.2-GGUF/IQ2_KS/GLM-5.2-smol-IQ2_KS-00001-of-00033.gguf";
  extras = {
    context = 131072;
    threads = 24;
    ubatch_size = 2048;
    mmap = false;                         # 205 GiB resident; --no-mmap avoids fault stalls
    llama_server = "${config.ai.ikLlamaCppCuda}/bin/llama-server";
    runtime = { kind = "ik-llama"; mla = 1; dsa = true; fit = true; attn_max_batch = 512; };
    devices = { placement = "hybrid"; };
  };
}
```

**The `--fit` margin trap — read this before benchmarking by hand.** ik's `--fit` auto-places layers, but accounts only weights + KV, *not* per-feature runtime buffers (prefill scratch, the DSA indexer, an MTP draft context). An unmargined `--fit` loads clean, passes the health check, then **OOMs on the first request** — a deferred failure that looks healthy until traffic arrives.

ananke computes `--gpu-fit-margin` per device automatically from the runtime config. Driving `ik-llama-server` directly for a benchmark, you set it yourself: budget ~2 GiB/card for ub2048 prefill scratch, +3 GiB/card if `dsa`, and +~4 GiB on device 0 if MTP is on.

**Knobs that mattered** (GLM-5.2 smol-IQ2_KS; your model will differ, but the shape of the lessons holds):

- `-mla` **1, not 3, when using DSA.** mla 3 buys ~8% shallow prefill but silently defeats DSA's deep-prefill advantage (measured 143 → 61 tok/s at 58k). Without DSA the tradeoff reverses; benchmark it.
- `-dsa -fidx` — sparse attention. Flat generation and ~2× deep prefill vs dense MLA. Requires f16 KV: it rejects quantised cache types and `-sm graph`.
- `-rtr` (runtime repack) — unnecessary for `KS` quants (already CPU-fast) and adds minutes to load. Worth a trial on other i-quants.
- `-sm graph`, `-khad` — both rejected here: `-sm graph` gave noise-level gains while saturating one card and OOMing prefill; `-khad` + quantised KV broke `--fit`. Don't assume; they may suit another model.

**MTP is a mirage on real text.** `--spec-type mtp:n_max=4` benched at 10.6 tok/s — but that was **1.00 draft acceptance on repetitive benchmark text**. On real prompts acceptance fell to 0.63 and MTP dropped *below* the no-MTP baseline, because rejected drafts cost more than they save.

Always measure acceptance on realistic prompts. MTP only wins for highly predictable output — structured JSON, code edits. (The dialect differs too: ik takes `mtp:n_max=…`, mainline takes `draft-mtp`.)

The reference config (`mla=1`, `dsa`, `fit`, f16 KV, ub2048, 128k) lands ~8 tok/s flat to 58k+ depth and ~195/143 tok/s prefill shallow/deep on the *Machine*. See the model dir's `bench/TRIALS.md` + `RECOMMENDED.md` for the full trail.

## Benchmarking

Only worth doing when tuning a hybrid config or comparing placements.

**Two cheap checks before you trust any number:**

- **Governor.** `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`. `powersave` on `acpi-cpufreq` pins every core to the base-clock floor and silently halves CPU-bound throughput — it cost ~40% here before it was caught, invalidating a run of earlier numbers. Want `schedutil`, `ondemand`, or `performance`.
- **What others found.** For a big or novel model, skim r/LocalLLaMA and the HF quant-repo discussions (unsloth, ubergarm, muzzy, sokann) for comparable hardware first. They set expectations and surface known-good flags and quants before you sweep blind — and reveal dead ends (e.g. that MTP is a mirage, or which fork features have landed).

**How to run the sweep:**

- **Benchmark before you import.** For a model that needs tuning, drive `llama-server` / `ik-llama-server` directly and settle the config first; write the ananke entry *last*. Importing an untuned config just makes you tune through the daemon, slowly.
- **One benchmark at a time.** Runs are CPU/GPU/RAM/page-cache bound; a build or a second trial alongside corrupts the numbers. Never compile during a run.
- **Drive it adaptively.** A findings-driven sweep beats a fixed script — the next trial almost always depends on the last result (a dead branch, a surprising win). Keep a script as the playbook and the idle-GPU gate, not as the unattended driver.

The service must be **loaded first** (they're on-demand and idle out), and the script needs the **raw llama-server proxy**, not the OpenAI multiplexer — 7070 speaks a different API and has no `/completion`. Find the port with `anankectl services` or count the model's index in `models` and add it to 8200.

```
anankectl start <name>
./agentic-bench.py --url http://127.0.0.1:82NN --scenario turns   # agentic-bench.py ships alongside this skill
```

Scenarios: `turns` (agent loop with prompt-cache reuse), `prefill` (cold, cache off), `depth` (generation as context fills).

For spec-decode acceptance testing, use `coding-bench.py` (also alongside this skill). It sends realistic coding prompts (system + tool defs + multi-language requests) instead of repetitive filler text, so acceptance numbers reflect what an agent actually produces rather than what a drafter can memorise.

Use `turns` for anything agentic — coding agents, tool-driven loops. Those loops re-send a growing prefix every turn, so llama.cpp's prompt cache prefills only the delta and felt latency is far better than a cold-prefill number implies. Benchmarking with `cache_prompt: false` understates agentic performance badly. Prefill *seconds per turn* is what the agent waits on; quote that.

Traps that produce wrong numbers:

- **Never benchmark with `-v`.** It serialises every graph op and reported 1.2 tok/s on a model that really did ~3.5.
- **Discard the first run.** A cold GGUF read measured 1.5 tok/s where warm was 2.9. The script warms up for you.
- **Measure generation and prefill separately.** Different knobs, and they trade against each other.
- **Expect ±0.5 tok/s of noise.** Don't chase smaller differences.
- **Spec-decode acceptance is workload-specific.** A draft-model / MTP config that looks great on repetitive bench text can lose on real text (0.63 vs 1.00 acceptance → below baseline). Measure acceptance on realistic prompts, not the synthetic loop. If acceptance is low, try `--spec-draft-p-min 0.8` (poolside) or the equivalent minimum-probability filter on the drafter — it prevents low-confidence drafts from wasting forward passes, and was the difference between 0.12 acceptance (net loss, 2.75 tok/s) and 0.84 acceptance (near break-even, 17.4 tok/s) on Laguna DFlash coding prompts. Without a p_min filter, the drafter submits everything it generates; with one, it only submits when it's confident enough to be worth verifying.
- **Wait for CUDA teardown between trials.** Killing a multi-GiB server takes seconds to release VRAM; launching the next too fast makes `--fit` (and ananke placement) under-count free memory and fail on args that worked a moment earlier.
- **Depth matters for sparse-attention models.** A shallow-context number hides how generation and prefill hold up as context fills — run the `depth` scenario, since that's where DSA-style architectures earn their keep or don't.

Log trials to `bench/TRIALS.md` in the model's directory under the model dir. Worked examples exist for DeepSeek-V4-Flash and gemma-4-31B-it-qat, including the `RECOMMENDED.md` companion that `ananke.nix` comments cite by name — copy their format.

## One GPU or two

Two cards aren't automatically faster, and for hybrid models they're often worse. Test it.

`--split-mode layer` is a pipeline, not parallelism: for a single request only one GPU computes at a time. Spanning two cards buys **VRAM capacity, not single-stream speed**. `devices.split = "tensor"` does give real parallelism (the Qwen 3.6 and Gemma 4 QAT entries use it), but it requires `placement = "gpu-only"` and isn't supported by every architecture. On MoE models, `-sm tensor` is crash-prone: the meta backend's `GGML_ASSERT` failures in `ggml_backend-meta.cpp` need patching (the `fattn-graph-reuse-fix` and a `SUM_ROWS` axis-0 fix). Layer split (`-sm layer`, the default) is the safe path; test tensor split before relying on it.

A second card also costs a full compute buffer and CUDA context (per-device, so a large buffer is paid twice), cross-GPU transfers at every layer boundary that spans cards, and a card that can't host anything else.

So if the GPU-resident portion fits on one card, prefer one. Same tokens/sec, simpler config, and a whole 3090 freed — usually worth more than a marginal gain.

Pin a llama-cpp service to one card with `devices.placement_override = { "gpu:0" = <MiB>; }`, which also reserves that much for it. Don't reach for `CUDA_VISIBLE_DEVICES` — ananke owns the child's environment and derives that variable itself. (`gpu_indices` looks like the obvious key but isn't one: it's a helper in `ananke.nix`'s vLLM builder that expands to `placement_override`, and it's unavailable to llama-cpp entries.)

## Adding an architecture

Two halves: llama.cpp must support it, and ananke's estimator must size it. Check **both** runtimes — ik_llama.cpp may support an arch (or a quant, or a feature like DSA) that mainline at your pin doesn't, and sometimes lands it first. If mainline rejects the arch, the fork is worth a look before you write off the model. Vendors may also publish their own llama.cpp fork with arch support before it reaches mainline or ik_llama — check the model card for a recommended fork/branch if neither runtime recognises the architecture.

**Check llama.cpp against the revision you actually run.** The pin lives in `inputs.llama-cpp.url` in the llama.cpp flake (path in *Parameters*); the source checkout drifts from it, so sync first:

```
cd ~/programming/llama.cpp
REV=$(grep -oP 'llama.cpp/\K[0-9a-f]{40}' ~/nixos-configuration/nixos/redline/ai/llama-flake/flake.nix)
git fetch origin "$REV" && git checkout "$REV"
```

(That directory also has an `update.sh` for bumping the pin to a newer upstream ref.)

Then read the source. **Don't trust a merge PR's TODO list** — they go stale, and a feature listed as unimplemented may well have landed. Check the code at the revision you run. `strings <libllama.so> | grep -i <arch>` confirms the arch reached the built binary, which a checkout can't tell you.

**Then teach the estimator.** Follow ananke's `CONTRIBUTING.md` under "adding a new model architecture": register the arch in the right family, model its KV if it deviates from the family default, and calibrate a compute-buffer curve as `base + slope × (ctx / 1024)` MiB per device.

Two tricks make calibration tractable:

- **Isolate KV** by comparing total VRAM at `f16` versus `q8_0` cache. Compute buffers don't depend on cache type, so the delta is pure KV.
- **Isolate the compute buffer** as the residual: per-card VRAM, minus GPU-resident weights, minus KV.

Fit *above* the measured points. Over-reserving costs a little capacity; under-reserving OOMs at load.

Don't assume KV caps context. For compressed-attention architectures it can be an order of magnitude below the naive `n_layers × n_kv_heads × (k_len + v_len)` estimate, while the prefill compute buffer becomes the real limit — for sparse attention it can scale with `ubatch × context` and dwarf the weights.

Finally: `cargo build`, restart the daemon, and load the model. A green test suite proves the plan; only a live load proves the model runs.
