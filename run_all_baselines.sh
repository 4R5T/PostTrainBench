cat > run_all_baselines.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

MODEL="${MODEL:-Qwen/Qwen3-1.7B-Base}"
TEMPLATES_DIR="${TEMPLATES_DIR:-src/eval/templates}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUTDIR_REL="${OUTDIR:-results/baseline_$(echo "$MODEL" | tr '/:' '__')_${STAMP}}"
OUTDIR="${REPO_ROOT}/${OUTDIR_REL}"
LOGDIR="${LOGDIR:-${OUTDIR_REL}/logs}"
LOGDIR="${REPO_ROOT}/${LOGDIR}"
mkdir -p "${OUTDIR}" "${LOGDIR}"

DEFAULT_CONN="${DEFAULT_CONN:-3}"
DEFAULT_UTIL="${DEFAULT_UTIL:-0.85}"
DEFAULT_MAX_TOKENS="${DEFAULT_MAX_TOKENS:-4000}"
DEFAULT_MAX_NEW_TOKENS="${DEFAULT_MAX_NEW_TOKENS:-4000}"
DEFAULT_JUDGE_WORKERS="${DEFAULT_JUDGE_WORKERS:-2}"
LIMIT="${LIMIT:-}"

echo "==> Repo:          ${REPO_ROOT}"
echo "==> Model:         ${MODEL}"
echo "==> Templates dir: ${TEMPLATES_DIR}"
echo "==> Outdir:        ${OUTDIR}"
echo "==> Logdir:        ${LOGDIR}"
[ -n "${LIMIT}" ] && echo "==> Limit:         ${LIMIT}"
echo

choose_defaults () {
  local task="$1"
  CONN="$DEFAULT_CONN"
  UTIL="$DEFAULT_UTIL"
  MAX_TOKENS="$DEFAULT_MAX_TOKENS"
  MAX_NEW_TOKENS="$DEFAULT_MAX_NEW_TOKENS"
  JUDGE_WORKERS="$DEFAULT_JUDGE_WORKERS"

  case "$task" in
    gsm8k)
      CONN="${GSM8K_CONN:-3}"; UTIL="${GSM8K_UTIL:-0.85}"
      MAX_TOKENS="${GSM8K_MAX_TOKENS:-4000}"; MAX_NEW_TOKENS="${GSM8K_MAX_NEW_TOKENS:-4000}"
      ;;
    humaneval)
      CONN="${HUMANEVAL_CONN:-1}"; UTIL="${HUMANEVAL_UTIL:-0.85}"
      MAX_TOKENS="${HUMANEVAL_MAX_TOKENS:-4000}"; MAX_NEW_TOKENS="${HUMANEVAL_MAX_NEW_TOKENS:-4000}"
      ;;
    gpqa*|gpqa_main|gpqa)
      CONN="${GPQA_CONN:-2}"; UTIL="${GPQA_UTIL:-0.90}"
      MAX_TOKENS="${GPQA_MAX_TOKENS:-8000}"; MAX_NEW_TOKENS="${GPQA_MAX_NEW_TOKENS:-8000}"
      ;;
    arena*|arena_hard|arenahard*|arenahardwriting*)
      CONN="${ARENA_CONN:-2}"; UTIL="${ARENA_UTIL:-0.90}"
      MAX_TOKENS="${ARENA_MAX_TOKENS:-8000}"; MAX_NEW_TOKENS="${ARENA_MAX_NEW_TOKENS:-8000}"
      JUDGE_WORKERS="${ARENA_JUDGE_WORKERS:-2}"
      ;;
    bfcl*)
      CONN="${BFCL_CONN:-2}"; UTIL="${BFCL_UTIL:-0.90}"
      MAX_TOKENS="${BFCL_MAX_TOKENS:-16000}"; MAX_NEW_TOKENS="${BFCL_MAX_NEW_TOKENS:-16000}"
      ;;
    healthbench*|health_bench|healthbench)
      CONN="${HB_CONN:-2}"; UTIL="${HB_UTIL:-0.90}"
      MAX_TOKENS="${HB_MAX_TOKENS:-6000}"; MAX_NEW_TOKENS="${HB_MAX_NEW_TOKENS:-6000}"
      ;;
    aime*|aime_2025|aime2025)
      CONN="${AIME_CONN:-2}"; UTIL="${AIME_UTIL:-0.90}"
      MAX_TOKENS="${AIME_MAX_TOKENS:-12000}"; MAX_NEW_TOKENS="${AIME_MAX_NEW_TOKENS:-12000}"
      ;;
  esac
}

run_task () {
  local eval_py_rel="$1"              # e.g. src/eval/tasks/xxx/evaluate.py
  local eval_py_abs="${REPO_ROOT}/${eval_py_rel}"
  local task_dir_rel
  task_dir_rel="$(dirname "$eval_py_rel")"
  local task
  task="$(basename "$task_dir_rel")"

  choose_defaults "$task"

  local out_json="${OUTDIR}/${task}.json"
  local out_log="${LOGDIR}/${task}.log"

  if [ -f "$out_json" ]; then
    echo "==> SKIP (exists): $task -> $out_json"
    return 0
  fi

  echo "==> RUN: $task"
  echo "    eval:   $eval_py_rel"
  echo "    cwd:    ${REPO_ROOT}/${task_dir_rel}"
  echo "    out:    $out_json"
  echo "    log:    $out_log"

  # IMPORTANT: run from task directory so relative data paths work
  pushd "${REPO_ROOT}/${task_dir_rel}" >/dev/null

  local help_text
  help_text="$(python3 "$(basename "$eval_py_abs")" -h 2>&1 || true)"

  local args=(
    "--model-path" "$MODEL"
    "--templates-dir" "${REPO_ROOT}/${TEMPLATES_DIR}"
    "--json-output-file" "$out_json"
  )

  if echo "$help_text" | grep -q -- "--max-connections"; then
    args+=("--max-connections" "$CONN")
  fi
  if echo "$help_text" | grep -q -- "--gpu-memory-utilization"; then
    args+=("--gpu-memory-utilization" "$UTIL")
  fi
  if echo "$help_text" | grep -q -- "--max-tokens"; then
    args+=("--max-tokens" "$MAX_TOKENS")
  fi
  if echo "$help_text" | grep -q -- "--max-new-tokens"; then
    args+=("--max-new-tokens" "$MAX_NEW_TOKENS")
  fi
  if [ -n "${LIMIT}" ] && echo "$help_text" | grep -q -- "--limit"; then
    args+=("--limit" "$LIMIT")
  fi
  if echo "$help_text" | grep -q -- "--judge-workers"; then
    args+=("--judge-workers" "$JUDGE_WORKERS")
  fi

  {
    echo "---- Command ----"
    printf 'cd %q\n' "$(pwd)"
    printf 'python3 %q ' "$(basename "$eval_py_abs")"
    printf '%q ' "${args[@]}"
    echo
    echo "-----------------"
  } | tee "$out_log"

  python3 "$(basename "$eval_py_abs")" "${args[@]}" 2>&1 | tee -a "$out_log"

  popd >/dev/null
  echo
}

# discover tasks
cd "$REPO_ROOT"
mapfile -t EVALS < <(find src/eval/tasks -maxdepth 2 -type f -name evaluate.py | sort)
echo "==> Found ${#EVALS[@]} tasks"
echo

for eval_py in "${EVALS[@]}"; do
  run_task "$eval_py"
done

echo "==> DONE. Results: ${OUTDIR}"
BASH

chmod +x run_all_baselines.sh
