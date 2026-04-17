# opencode-vllm-mlx

**How to get [opencode](https://opencode.ai) talking to a local
[vllm-mlx](https://pypi.org/project/vllm-mlx/) server running
`Qwen/Qwen3.6-35B-A3B` on an Apple Silicon Mac.**

That's it. This repo is the scripts and config you need to wire those
three pieces together. The model runs locally, opencode uses it as an
OpenAI-compatible provider over `http://localhost:8899`.

## Prerequisites

- **Apple Silicon Mac.** MLX is Metal-only — nothing else works.
- **Unified memory:**
  - Required: **≥64 GB** (below this, the model + OS won't coexist).
  - Recommended: **≥72 GB** (below this, expect the OS to swap under load).
  - Comfortable: 96–128 GB. The model itself runs at ~62 GB resident.
- **≥70 GB free disk** on `$HOME` for the model download + Hugging Face cache.
- macOS recent enough for MLX 0.31.x (tested on Darwin 25.4.0 / M5 Max / 128 GB).
- [`uv`](https://github.com/astral-sh/uv) on `PATH`.
- [`opencode`](https://opencode.ai) on `PATH`.
- Python 3.11 (uv handles this).

`./scripts/setup.sh` verifies all of the above before doing anything.

## Setup

```bash
git clone <this-repo> && cd opencode-vllm-mlx
./scripts/setup.sh
```

`setup.sh` checks prerequisites, runs `uv sync`, and writes the
`vllm-mlx` provider block to `~/.config/opencode/opencode.json` (or prints
it for you to merge if the file already exists).

## Running

```bash
./scripts/start.sh    # boots vllm-mlx on :8899, blocks until smoke test passes
./scripts/oc.sh       # launches opencode TUI (in another shell)
```

Pick the `vllm-mlx/Qwen/Qwen3.6-35B-A3B` model inside opencode. Stop the
server with `kill "$(cat /tmp/vllm-mlx.pid)"`.

## Gotchas

- **Metal shared event pool leak.** MLX 0.31.x leaks `MTLSharedEvent`
  handles during long agentic sessions. When it exhausts you get
  `RuntimeError: [Event::Event] Failed to create Metal shared event.` and
  Metal is broken **system-wide** — even a trivial `mx.ones((2,2))` in a
  fresh process fails. **Only a full machine reboot fixes it.**
  Restarting the server, killing other GPU processes, or waiting does not.
  Upstream: [ml-explore/mlx#887](https://github.com/ml-explore/mlx/issues/887),
  partial fix in [PR #3159](https://github.com/ml-explore/mlx/pull/3159).
  Full post-mortem in `docs/20260417-shared-event-crash.md`.

- **Thinking mode is disabled on purpose.** `VLLM_MLX_ENABLE_THINKING=false`
  is set in `start.sh`. Qwen3.x thinking burns 4–16K tokens of invisible
  reasoning against `max_tokens`, which causes mid-task stops at 16K on
  coding runs. Do not turn it back on unless you also raise `output` limit.

- **opencode web search needs an env var, not a config setting.**
  `scripts/oc.sh` sets `OPENCODE_ENABLE_EXA=true` — there's no
  `opencode.json` field for it
  ([opencode#309](https://github.com/anomalyco/opencode/issues/309)).

- **The opencode config lives outside this repo** in
  `~/.config/opencode/opencode.json`. `setup.sh` writes it there. If you
  blow that file away you'll lose the provider and need to re-run setup.

- **Port 8899** is hardcoded in `start.sh` and the opencode provider. If
  you change one, change the other.

- **Short responses feel slow.** ~12–20 tok/s on short outputs vs.
  ~35–46 tok/s on long ones. Prefill dominates on large agentic context
  (24 tools + 60+ messages). Not a bug — that's the shape of MoE on
  Apple Silicon.

## Layout

```
scripts/
  setup.sh                        one-shot installer
  start.sh                        launch vllm-mlx
  oc.sh                           opencode wrapper with Exa enabled
docs/
  20260417-shared-event-crash.md  Metal event leak post-mortem
  system-prompt-proposal.md       Qwen3.6-tuned system prompt draft
```

## License

Apache-2.0.
