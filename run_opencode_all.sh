#!/bin/bash
set -euo pipefail

# Run OpenCode on all benchmark tasks
# Usage: bash run_opencode_all.sh [model] [hours] [agent_config]

MODEL_TO_TRAIN="${1:-Qwen/Qwen3-1.7B-Base}"
NUM_HOURS="${2:-10}"
AGENT_CONFIG="${3:-opencode/big-pickle}"

echo "========================================"
echo "OpenCode All Tasks (No Container)"
echo "========================================"
echo "Model:        $MODEL_TO_TRAIN"
echo "Hours:        $NUM_HOURS per task"
echo "Agent Config: $AGENT_CONFIG"
echo "========================================"
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

# All available tasks
TASKS=(
    "aime2025"
    "arenahardwriting"
    "bfcl"
    "gpqamain"
    "gsm8k"
    "humaneval"
    "healthbench"
)

echo "Tasks to run: ${TASKS[@]}"
echo ""

# Track results
declare -A TASK_STATUS
declare -A TASK_TIME
START_ALL=$(date +%s)

for task in "${TASKS[@]}"; do
    echo ""
    echo "========================================"
    echo "Starting task: $task"
    echo "========================================"
    
    TASK_START=$(date +%s)
    
    if bash run_opencode_single.sh "$task" "$MODEL_TO_TRAIN" "$NUM_HOURS" "$AGENT_CONFIG"; then
        TASK_STATUS[$task]="✓ SUCCESS"
    else
        TASK_STATUS[$task]="✗ FAILED"
    fi
    
    TASK_END=$(date +%s)
    TASK_TIME[$task]=$((TASK_END - TASK_START))
    
    echo ""
    echo "Task $task completed: ${TASK_STATUS[$task]}"
    echo ""
done

END_ALL=$(date +%s)
TOTAL_TIME=$((END_ALL - START_ALL))

# Summary
echo ""
echo "========================================"
echo "============== SUMMARY ================="
echo "========================================"
echo "Model:        $MODEL_TO_TRAIN"
echo "Agent:        $AGENT_CONFIG"
echo "Total time:   $(printf '%02d:%02d:%02d' $((TOTAL_TIME / 3600)) $(((TOTAL_TIME % 3600) / 60)) $((TOTAL_TIME % 60)))"
echo ""
echo "Task Results:"
echo "----------------------------------------"

for task in "${TASKS[@]}"; do
    TIME_STR=$(printf '%02d:%02d:%02d' $((TASK_TIME[$task] / 3600)) $(((TASK_TIME[$task] % 3600) / 60)) $((TASK_TIME[$task] % 60)))
    printf "  %-20s %s (%s)\n" "$task" "${TASK_STATUS[$task]}" "$TIME_STR"
done

echo "========================================"
echo ""
echo "Results saved to: results/"
echo ""

# Find and display all evaluation results
echo "Final Evaluation Scores:"
echo "----------------------------------------"
for task in "${TASKS[@]}"; do
    EVAL_JSON=$(find results -name "final_evaluation.json" -path "*/${task}_*" | head -1)
    if [ -f "$EVAL_JSON" ]; then
        echo ""
        echo "$task:"
        python -c "
import json
try:
    data = json.load(open('$EVAL_JSON'))
    results = data.get('results', {})
    if results:
        for key, val in results.items():
            print(f'  {key}: {val}')
    else:
        print('  (no results found)')
except Exception as e:
    print(f'  Error: {e}')
" || echo "  (failed to parse)"
    else
        echo ""
        echo "$task: (no evaluation file found)"
    fi
done

echo ""
echo "========================================"
