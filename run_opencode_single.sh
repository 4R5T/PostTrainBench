#!/bin/bash
set -euo pipefail

# Simple script to run OpenCode agent directly (no containers, no HTCondor)
# Usage: bash run_opencode_single.sh <task> <model> <hours> <agent_config>
# Example: bash run_opencode_single.sh gsm8k Qwen/Qwen3-1.7B-Base 10 opencode/big-pickle

EVALUATION_TASK="${1:-gsm8k}"
MODEL_TO_TRAIN="${2:-Qwen/Qwen3-1.7B-Base}"
NUM_HOURS="${3:-10}"
AGENT_CONFIG="${4:-opencode/big-pickle}"
AGENT="opencode"

echo "==================================="
echo "OpenCode Direct Run (No Container)"
echo "==================================="
echo "Task:         $EVALUATION_TASK"
echo "Model:        $MODEL_TO_TRAIN"
echo "Hours:        $NUM_HOURS"
echo "Agent Config: $AGENT_CONFIG"
echo "==================================="
echo ""

# Check requirements
if ! command -v opencode &> /dev/null; then
    echo "ERROR: opencode-ai not found. Install with:"
    echo "  npm install -g opencode-ai"
    exit 1
fi

if [ -z "${OPENCODE_API_KEY:-}" ]; then
    echo "ERROR: OPENCODE_API_KEY not set"
    echo "Get your free key from: https://opencode.ai/auth"
    echo "Then: export OPENCODE_API_KEY='your-key'"
    exit 1
fi

# Setup directories
RESULT_PREFIX_SAFE=$(echo "$MODEL_TO_TRAIN" | tr '/:' '_')
AGENT_CONFIG_SAFE=$(echo "$AGENT_CONFIG" | tr '/:' '_')
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CLUSTER_ID="${TIMESTAMP}"

export EVAL_DIR="results/${AGENT}_${AGENT_CONFIG_SAFE}_${NUM_HOURS}h/${EVALUATION_TASK}_${RESULT_PREFIX_SAFE}_${CLUSTER_ID}"
mkdir -p "${EVAL_DIR}"

# Create working directory
WORK_DIR="${EVAL_DIR}/task"
mkdir -p "${WORK_DIR}"

echo "Working directory: ${WORK_DIR}"
echo "Results directory: ${EVAL_DIR}"
echo ""

# Copy evaluation files
echo "==> Preparing task files..."
cp "src/eval/tasks/${EVALUATION_TASK}/evaluate.py" "${WORK_DIR}/"
if [ -d "src/eval/tasks/${EVALUATION_TASK}/evaluation_code" ]; then
    cp -r "src/eval/tasks/${EVALUATION_TASK}/evaluation_code" "${WORK_DIR}/"
fi
cp -r src/eval/templates "${WORK_DIR}/"

if [ -d "src/eval/tasks/${EVALUATION_TASK}/task_context" ]; then
    cp -r "src/eval/tasks/${EVALUATION_TASK}/task_context/"* "${WORK_DIR}/"
fi

# Get benchmark name and create prompt
BENCHMARK=$(cat "src/eval/tasks/${EVALUATION_TASK}/benchmark.txt")
PROMPT=$(python src/eval/general/get_prompt.py \
    --model-to-train "$MODEL_TO_TRAIN" \
    --benchmark-id "$EVALUATION_TASK" \
    --num-hours "$NUM_HOURS" \
    --agent "${AGENT}")

echo "$PROMPT" > "${EVAL_DIR}/prompt.txt"
echo "==> Prompt saved to: ${EVAL_DIR}/prompt.txt"
echo ""

# Create timer script
bash src/utils/create_timer.sh "$NUM_HOURS" "${WORK_DIR}/timer.sh"

# Create OpenCode config
cd "${WORK_DIR}"
cat > opencode.json << 'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": "allow",
  "provider": {
    "opencode": {
      "options": {
        "apiKey": "{env:OPENCODE_API_KEY}"
      }
    }
  }
}
EOF

echo "==================================="
echo "======= STARTING OPENCODE ========="
echo "==================================="
echo ""

# Run OpenCode
START_TIME=$(date +%s)

opencode run --model "$AGENT_CONFIG" --format json "$PROMPT" 2>&1 | tee "${EVAL_DIR}/opencode_output.jsonl"
EXIT_CODE=${PIPESTATUS[0]}

END_TIME=$(date +%s)
TIME_TAKEN=$((END_TIME - START_TIME))

printf '%02d:%02d:%02d\n' \
    $((TIME_TAKEN / 3600)) \
    $(((TIME_TAKEN % 3600) / 60)) \
    $((TIME_TAKEN % 60)) > "${EVAL_DIR}/time_taken.txt"

echo ""
echo "==================================="
echo "======= OPENCODE COMPLETE ========="
echo "==================================="
echo "Exit code: $EXIT_CODE"
echo "Time taken: $(cat ${EVAL_DIR}/time_taken.txt)"
echo ""

# Parse OpenCode output if parser exists
if [ -f "../../scripts/parse_jsonl/opencode_parse_jsonl.py" ]; then
    echo "==> Parsing OpenCode output..."
    python ../../scripts/parse_jsonl/opencode_parse_jsonl.py \
        "${EVAL_DIR}/opencode_output.jsonl" \
        -o "${EVAL_DIR}/opencode_readable.txt" || true
fi

# Check if final_model was created
if [ -d "final_model" ]; then
    echo "==> Final model found! Copying to results..."
    cp -r final_model "${EVAL_DIR}/final_model"
    echo "    Saved to: ${EVAL_DIR}/final_model"
    
    # Run evaluation
    echo ""
    echo "==================================="
    echo "========== EVALUATING ============="
    echo "==================================="
    echo ""
    
    python evaluate.py \
        --model-path "${EVAL_DIR}/final_model" \
        --templates-dir "$(pwd)/templates" \
        --json-output-file "${EVAL_DIR}/final_evaluation.json" \
        2>&1 | tee "${EVAL_DIR}/evaluation.log"
    
    echo ""
    echo "==> Evaluation complete!"
    echo "    Results: ${EVAL_DIR}/final_evaluation.json"
    
    # Show score
    if [ -f "${EVAL_DIR}/final_evaluation.json" ]; then
        echo ""
        echo "==================================="
        echo "=========== RESULTS ==============="
        echo "==================================="
        python -c "import json; data=json.load(open('${EVAL_DIR}/final_evaluation.json')); print(json.dumps(data.get('results', {}), indent=2))" || cat "${EVAL_DIR}/final_evaluation.json"
    fi
else
    echo "⚠ WARNING: No final_model directory found"
    echo "   OpenCode may not have completed training"
    echo "   Check logs in: ${EVAL_DIR}/"
fi

echo ""
echo "==================================="
echo "============ SUMMARY =============="
echo "==================================="
echo "Task:           $EVALUATION_TASK"
echo "Model:          $MODEL_TO_TRAIN"
echo "Agent:          $AGENT_CONFIG"
echo "Time taken:     $(cat ${EVAL_DIR}/time_taken.txt)"
echo "Results dir:    ${EVAL_DIR}"
echo ""
echo "Key files:"
echo "  - ${EVAL_DIR}/prompt.txt                 (agent prompt)"
echo "  - ${EVAL_DIR}/opencode_output.jsonl      (raw output)"
echo "  - ${EVAL_DIR}/opencode_readable.txt      (parsed trace)"
echo "  - ${EVAL_DIR}/final_model/               (trained model)"
echo "  - ${EVAL_DIR}/final_evaluation.json      (scores)"
echo "==================================="
