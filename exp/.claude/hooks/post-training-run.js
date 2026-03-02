#!/usr/bin/env node
/**
 * PostToolUse hook: Detect training run completion and remind Claude to write critique.md
 *
 * Fires after every Bash tool call. Checks if the command looks like a training
 * script that just finished (python train*.py, torchrun, accelerate launch, etc.).
 * If so, prints a structured reminder to stderr — Claude sees this and is nudged
 * to follow Stage 4 of the experiment pipeline.
 *
 * Exit 0 always (PostToolUse hooks cannot block).
 */

const TRAINING_PATTERNS = [
  /python\s+.*train/i,
  /torchrun\b/,
  /accelerate\s+launch/,
  /python\s+-m\s+(torch\.distributed|trl|transformers)/,
  /deepspeed\b/,
  /llamafactory-cli\s+train/i,
  /python\s+.*finetune/i,
  /python\s+.*sft/i,
  /python\s+.*rlhf/i,
  /python\s+.*dpo/i,
  /python\s+.*grpo/i,
  /python\s+.*ppo/i,
];

// Only alert if the command ran for a meaningful duration (output has training keywords)
const TRAINING_OUTPUT_SIGNALS = [
  /loss[:=\s]/i,
  /epoch\s+\d/i,
  /step\s+\d+/i,
  /accuracy[:=\s]/i,
  /train.*loss/i,
  /val.*loss/i,
  /eval.*acc/i,
  /saved.*checkpoint/i,
  /training complete/i,
  /finished training/i,
];

let data = '';
process.stdin.on('data', chunk => data += chunk);
process.stdin.on('end', () => {
  try {
    const input = JSON.parse(data);
    const cmd = input.tool_input?.command || '';
    const output = input.tool_response?.output || input.tool_output?.output || '';

    const looksLikeTraining = TRAINING_PATTERNS.some(p => p.test(cmd));
    const outputHasTrainingSignals = TRAINING_OUTPUT_SIGNALS.some(p => p.test(output));

    if (looksLikeTraining && outputHasTrainingSignals) {
      console.error('');
      console.error('╔═══════════════════════════════════════════════════════════════╗');
      console.error('║  [Pipeline Hook] Training run detected — Stage 4 required     ║');
      console.error('╠═══════════════════════════════════════════════════════════════╣');
      console.error('║  Before continuing, write {run_dir}/critique.md with:         ║');
      console.error('║    ## What happened  (accuracy, loss curve, anomalies)        ║');
      console.error('║    ## What worked                                             ║');
      console.error('║    ## What didn\'t work                                        ║');
      console.error('║    ## Hypotheses                                              ║');
      console.error('║    ## Recommendations for next run                            ║');
      console.error('║    ## Informed by prior runs                                  ║');
      console.error('║                                                               ║');
      console.error('║  Also update plan.md: mark completed step with [x]           ║');
      console.error('╚═══════════════════════════════════════════════════════════════╝');
      console.error('');
    }
  } catch {
    // Malformed input — silently pass through
  }

  // PostToolUse hooks must echo stdin to stdout
  process.stdout.write(data);
});
