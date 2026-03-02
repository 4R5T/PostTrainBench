#!/usr/bin/env node
/**
 * PreToolUse hook: Enforce pipeline stage ordering for Write/Edit tool calls.
 *
 * Rules enforced:
 *   1. Writing plan.md requires literature_notes.md to already exist in the same dir.
 *   2. Writing any *.py or train/run script requires plan.md to exist in the same dir.
 *
 * These map directly to the Stage 1 → 2 → 3 ordering in CLAUDE.md.
 * Exit 2 to BLOCK the tool call and show an actionable error.
 * Exit 0 to ALLOW (pass-through).
 *
 * Note: "same dir" = we walk up from the file path to find the experiment root,
 * defined as the first directory that contains plan.md or literature_notes.md,
 * or fall back to the file's own directory.
 */

const fs = require('fs');
const path = require('path');

// Walk up from `startDir` looking for a directory that contains `filename`.
// Returns the directory path if found within `maxDepth` levels, else null.
function findAncestorDir(startDir, filename, maxDepth = 4) {
  let dir = startDir;
  for (let i = 0; i <= maxDepth; i++) {
    if (fs.existsSync(path.join(dir, filename))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) break; // filesystem root
    dir = parent;
  }
  return null;
}

// Determine the "experiment root" for a given file path.
// It's the closest ancestor that looks like an experiment directory.
function findExpRoot(filePath) {
  const dir = path.dirname(path.resolve(filePath));
  // Prefer a dir that already has one of the pipeline files
  return (
    findAncestorDir(dir, 'plan.md') ||
    findAncestorDir(dir, 'literature_notes.md') ||
    dir
  );
}

function block(reason, action) {
  console.error('');
  console.error('╔══════════════════════════════════════════════════════════════════╗');
  console.error('║  [Pipeline Hook] Stage ordering violation — BLOCKED              ║');
  console.error('╠══════════════════════════════════════════════════════════════════╣');
  console.error(`║  ${reason.padEnd(66)}║`);
  console.error('║                                                                  ║');
  console.error(`║  Action required:                                                ║`);
  console.error(`║  ${action.padEnd(66)}║`);
  console.error('╚══════════════════════════════════════════════════════════════════╝');
  console.error('');
  process.exit(2);
}

let data = '';
process.stdin.on('data', chunk => data += chunk);
process.stdin.on('end', () => {
  try {
    const input = JSON.parse(data);
    const filePath = input.tool_input?.file_path || '';

    if (!filePath) {
      process.stdout.write(data);
      return;
    }

    const basename = path.basename(filePath);
    const expRoot = findExpRoot(filePath);

    // Rule 1: Writing plan.md → literature_notes.md must exist
    if (basename === 'plan.md') {
      const litNotes = path.join(expRoot, 'literature_notes.md');
      if (!fs.existsSync(litNotes)) {
        block(
          'plan.md requires literature_notes.md first (Stage 1 → 2)',
          'Run Stage 1: use paper-search MCP, write literature_notes.md'
        );
      }
    }

    // Rule 2: Writing a Python training script → plan.md must exist
    // (only applies to files that look like experiment code, not utility scripts)
    const isTrainingScript = (
      /\.(py)$/.test(basename) &&
      /train|finetune|sft|rlhf|dpo|grpo|ppo|experiment|run_/.test(basename)
    );
    if (isTrainingScript) {
      const planFile = path.join(expRoot, 'plan.md');
      if (!fs.existsSync(planFile)) {
        block(
          `Writing ${basename} requires plan.md first (Stage 2 → 3)`,
          'Run Stage 2: create plan.md with checklist before writing code'
        );
      }
    }
  } catch {
    // Malformed input — allow through
  }

  // Always echo stdin to stdout (required for PreToolUse hooks)
  process.stdout.write(data);
});
