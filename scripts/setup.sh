#!/usr/bin/env bash
# Set up opencode + vllm-mlx + Qwen3.6-35B-A3B on an Apple Silicon Mac.
# Idempotent — safe to re-run.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"
PORT=8899
MODEL="Qwen/Qwen3.6-35B-A3B"

# Resource thresholds
MODEL_RSS_GB=62           # observed resident set of the model in memory
RAM_FAIL_GB=64            # below this, OS + model cannot coexist
RAM_WARN_GB=72            # below this, expect swap under load (user-stated: "approx 70GB")
DISK_NEED_GB=70           # download + HF cache overhead

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

fail=0
warned=0

bold "==> Checking prerequisites"

# 1. macOS + Apple Silicon (hard requirement — MLX is Metal/Apple-only)
if [[ "$(uname -s)" != "Darwin" ]] || [[ "$(uname -m)" != "arm64" ]]; then
    red "  ✗ Apple Silicon macOS required (got $(uname -sm)). MLX only runs on Apple GPUs."
    fail=1
else
    green "  ✓ Apple Silicon macOS ($(uname -sm))"
fi

# 2. RAM — tiered: hard fail below RAM_FAIL_GB, warn below RAM_WARN_GB
ram_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
ram_gb=$((ram_bytes / 1024 / 1024 / 1024))
if (( ram_gb < RAM_FAIL_GB )); then
    red "  ✗ RAM: ${ram_gb} GB — insufficient. Model alone needs ~${MODEL_RSS_GB} GB resident."
    red "    Minimum viable: ${RAM_FAIL_GB} GB. Comfortable: ≥${RAM_WARN_GB} GB."
    fail=1
elif (( ram_gb < RAM_WARN_GB )); then
    yellow "  ⚠ RAM: ${ram_gb} GB — tight. Model is ~${MODEL_RSS_GB} GB resident; OS will likely swap under load."
    yellow "    Close browser tabs and other heavy processes before running."
    warned=1
else
    green "  ✓ RAM: ${ram_gb} GB"
fi

# 3. Free disk (for model download + HF cache)
# df -g reports in GB (1024^3). Use $HOME as target — HF cache lives under ~/.cache/huggingface by default.
free_gb=$(df -g "$HOME" | awk 'NR==2 {print $4}')
if [[ -z "$free_gb" ]] || (( free_gb < DISK_NEED_GB )); then
    red "  ✗ Free disk on $HOME: ${free_gb:-?} GB — need ≥${DISK_NEED_GB} GB for model download + cache."
    fail=1
else
    green "  ✓ Free disk on \$HOME: ${free_gb} GB"
fi

# 4. uv
if ! command -v uv >/dev/null 2>&1; then
    red "  ✗ 'uv' not found. Install: https://github.com/astral-sh/uv"
    fail=1
else
    green "  ✓ uv: $(uv --version)"
fi

# 5. opencode
if ! command -v opencode >/dev/null 2>&1; then
    red "  ✗ 'opencode' not found. Install from https://opencode.ai"
    fail=1
else
    green "  ✓ opencode: $(opencode --version 2>/dev/null || echo 'installed')"
fi

# 6. Port availability (warn only — start.sh replaces its own instance)
if lsof -nPiTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    yellow "  ⚠ Port $PORT is already in use. start.sh will replace its own instance but will fail if another process owns it."
    warned=1
fi

if (( fail )); then
    red ""
    red "Prerequisites not met. Fix the items above and re-run."
    exit 1
fi

if (( warned )); then
    yellow ""
    yellow "Prerequisites met with warnings. Proceeding."
fi

bold ""
bold "==> Installing Python dependencies (vllm-mlx)"
cd "$PROJECT_DIR"
uv sync
green "  ✓ uv sync complete"

bold ""
bold "==> Checking opencode config at $OPENCODE_CONFIG"

provider_snippet=$(cat <<EOF
{
  "provider": {
    "vllm-mlx": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "vllm-mlx (local Qwen3.6-35B-A3B)",
      "options": {
        "baseURL": "http://localhost:${PORT}/v1",
        "apiKey": "none"
      },
      "models": {
        "${MODEL}": {
          "name": "Qwen3.6-35B-A3B via vllm-mlx",
          "limit": { "context": 262144, "output": 16384 }
        }
      }
    }
  }
}
EOF
)

if [[ ! -f "$OPENCODE_CONFIG" ]]; then
    mkdir -p "$(dirname "$OPENCODE_CONFIG")"
    printf '%s\n' "$provider_snippet" > "$OPENCODE_CONFIG"
    green "  ✓ Created $OPENCODE_CONFIG with the vllm-mlx provider."
elif command -v jq >/dev/null 2>&1 && jq -e '.provider."vllm-mlx"' "$OPENCODE_CONFIG" >/dev/null 2>&1; then
    green "  ✓ vllm-mlx provider already present in $OPENCODE_CONFIG — left untouched."
else
    yellow "  ⚠ $OPENCODE_CONFIG exists but has no 'vllm-mlx' provider."
    yellow "    Merge this block into the top-level \"provider\" object yourself:"
    echo ""
    echo "$provider_snippet"
    echo ""
fi

bold ""
bold "==> Model download"

# Check whether the snapshot is already cached
cache_dir="${HF_HOME:-$HOME/.cache/huggingface}/hub/models--${MODEL//\//--}"
if [[ -d "$cache_dir" ]] && find "$cache_dir/snapshots" -type f -name '*.safetensors' 2>/dev/null | grep -q .; then
    green "  ✓ Model already cached at $cache_dir"
else
    yellow "  Model not cached. First run of start.sh will download ~65 GB from Hugging Face."
    read -r -p "  Pre-download now? [y/N] " reply
    if [[ "$reply" =~ ^[Yy]$ ]]; then
        bold "  Downloading $MODEL..."
        uv run python -c "
from huggingface_hub import snapshot_download
snapshot_download('${MODEL}', allow_patterns=['*.json', '*.safetensors', '*.txt', 'tokenizer*'])
"
        green "  ✓ Model downloaded."
    else
        yellow "  Skipped. start.sh will pull it on first launch."
    fi
fi

bold ""
bold "==> Done. Next steps"
echo "  1. ./scripts/start.sh         # boots vllm-mlx on :${PORT}"
echo "  2. ./scripts/oc.sh            # launches opencode TUI"
echo "  3. Inside opencode, pick the 'vllm-mlx/${MODEL}' model."
