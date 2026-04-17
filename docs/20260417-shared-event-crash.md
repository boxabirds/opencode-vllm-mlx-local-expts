# Metal Shared Event Crash — 2026-04-17

## The Error

```
RuntimeError: [Event::Event] Failed to create Metal shared event.
```

Occurs in MLX 0.31.1 on macOS Darwin 25.4.0, 128GB Apple Silicon Mac, via vllm-mlx serving Qwen3.6-35B-A3B (~62GB resident memory).

## Root Cause

**Known MLX bug.** ml-explore/mlx#887 tracks the exact error. Fixed in MLX 0.31.0 via PR #3159 by @awni ("[Metal] Fix event leak"). The bug was in MLX itself — it wasn't properly releasing Metal shared events (`MTLSharedEvent`), causing the kernel-level event pool to exhaust over time.

**However, the fix is incomplete.** This crash occurred on MLX 0.31.1 (post-fix). A prior investigation on the same machine with dflash-mlx (also MLX 0.31.1) confirmed that the fix doesn't cover all leak paths, or cumulative usage over a session can still tip the pool. A Swift test calling `MTLDevice.makeSharedEvent()` in a fresh process also failed at iteration 0, confirming the exhaustion is system-wide and persists across process boundaries once triggered.

**This is NOT:**
- A macOS kernel bug (the Metal API is working as designed; MLX is the one leaking)
- Hardware-specific (affects any Apple Silicon Mac running MLX with enough eval cycles)
- Memory-related (96% free on a 128GB machine)

## Observed Behavior (2026-04-17, vllm-mlx)

1. **Crash at model load**: `mx.eval(model.parameters())` in `mlx_lm/utils.py:418` failed during first startup attempt
2. **Restarting the process did NOT fix it**: After killing and restarting vllm-mlx, the model loaded into memory successfully, but inference failed with the same error at `mx.eval([c.state for c in prompt_cache])` in `mlx_lm/generate.py:442` — health endpoint returned OK but chat completions returned HTTP 500
3. **System-wide Metal failure**: Even a trivial `mx.ones((2,2)); mx.eval(a)` in a fresh Python process fails. Metal is broken system-wide, not just for the crashed process.
4. **Killing Chrome GPU process did not help** — Metal remained broken
5. **Only a full machine reboot fixed it** — after reboot, `mx.eval` worked immediately, vllm-mlx started and served inference successfully

## Prior Investigation (2026-04-16, dflash-mlx)

A more thorough investigation on the same machine with dflash-mlx (speculative decoding, Qwen3.5-9B) found:

- dflash's streaming loop runs ~4-5 `mx.eval` calls per draft accept/verify cycle, draining the event pool over many requests
- Swift test confirmed `MTLDevice.makeSharedEvent()` returns nil system-wide once exhausted — even in brand new processes
- The pool does not recover without a reboot (killing individual GPU consumers doesn't help)
- The prior agent's claim that "events survive process death via kernel ref-counting" was challenged as unverified — standard macOS behavior reclaims kernel resources on process exit. The more likely explanation is that the Metal driver's session-level GPU state gets corrupted once the pool exhausts.

## What Works

- **Reboot** — the only reliable recovery once the pool is exhausted
- **MLX >= 0.31.0** — reduces but does not eliminate the leak (PR #3159)
- **Fewer eval cycles** — smaller prompts, no tool definitions, batched evals delay the onset

## What Doesn't Work

- Restarting the MLX/vllm-mlx process
- Killing other GPU processes (Chrome, etc.)
- Waiting — the pool does not self-recover

## References

- ml-explore/mlx#887 — the issue report for this exact error
- ml-explore/mlx PR #3159 — the (partial) fix by @awni, shipped in MLX 0.31.0
- Prior investigation: `~/.claude/projects/-Users-julian-tools-opencode-qwen-dflash/03d79ce6-f92f-4da8-a7a5-b0755a43b461.jsonl` (lines 547, 564, 576, 592, 599)

## Open Question

Why does MLX 0.31.1 (post-fix) still exhaust the pool? Either PR #3159 didn't patch all leak paths, or the fix only reduces the leak rate without eliminating it. Worth filing a follow-up on ml-explore/mlx with reproduction steps.
