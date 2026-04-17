#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_FILE="/tmp/vllm-mlx.log"
PID_FILE="/tmp/vllm-mlx.pid"
MODEL="Qwen/Qwen3.6-35B-A3B"
REASONING_PARSER="qwen3"
TOOL_CALL_PARSER="qwen3_coder"
PORT=8899

# Kill existing instance if running
if [[ -f "$PID_FILE" ]]; then
    old_pid=$(cat "$PID_FILE")
    if kill -0 "$old_pid" 2>/dev/null; then
        echo "Stopping existing vllm-mlx (PID $old_pid)..."
        kill "$old_pid"
        sleep 1
    fi
    rm -f "$PID_FILE"
fi

# Disable thinking mode — it eats the output token budget before the model
# gets to actual tool calls or code. Qwen3.x thinking uses ~4-16K tokens of
# internal reasoning that's invisible to the user but counts against max_tokens.
export VLLM_MLX_ENABLE_THINKING=false

echo "Starting vllm-mlx with $MODEL (thinking=off)..."
cd "$PROJECT_DIR"

uv run vllm-mlx serve "$MODEL" \
    --reasoning-parser "$REASONING_PARSER" \
    --enable-auto-tool-choice \
    --tool-call-parser "$TOOL_CALL_PARSER" \
    --port "$PORT" \
    > "$LOG_FILE" 2>&1 &

echo $! > "$PID_FILE"
echo "vllm-mlx started (PID $(cat "$PID_FILE")), logging to $LOG_FILE"
echo "Waiting for server to be ready..."

# Wait for server to start or fail (up to 120s)
MAX_WAIT=120
elapsed=0
while [[ $elapsed -lt $MAX_WAIT ]]; do
    if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "ERROR: vllm-mlx exited during startup."
        echo ""
        # Show the actual error: find ERROR/Traceback/RuntimeError lines, or fall back to last 10 lines
        if grep -qE "^(ERROR|Traceback|RuntimeError)" "$LOG_FILE" 2>/dev/null; then
            grep -A 2 -E "^(ERROR|Traceback|RuntimeError)" "$LOG_FILE" | tail -20
        else
            tail -10 "$LOG_FILE"
        fi
        exit 1
    fi
    if grep -q "Uvicorn running on" "$LOG_FILE" 2>/dev/null; then
        echo "Server is listening, running smoke test..."
        response=$(curl -s -w "\n%{http_code}" http://localhost:"$PORT"/v1/chat/completions \
            -H "Content-Type: application/json" \
            -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hi\"}],\"max_tokens\":16}" \
            --max-time 30 2>&1)
        http_code=$(echo "$response" | tail -1)
        if [[ "$http_code" == "200" ]]; then
            echo "Smoke test passed (HTTP $http_code). Server is ready!"
            exit 0
        else
            echo "ERROR: Smoke test failed (HTTP $http_code)."
            echo ""
            if grep -qE "^(ERROR|Traceback|RuntimeError)" "$LOG_FILE" 2>/dev/null; then
                grep -A 2 -E "^(ERROR|Traceback|RuntimeError)" "$LOG_FILE" | tail -20
            else
                echo "$response" | head -5
            fi
            kill "$(cat "$PID_FILE")" 2>/dev/null
            exit 1
        fi
    fi
    sleep 2
    elapsed=$((elapsed + 2))
done

echo "WARNING: Server still starting after ${MAX_WAIT}s."
tail -10 "$LOG_FILE"
