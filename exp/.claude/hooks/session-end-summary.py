#!/usr/bin/env python3
"""
SessionEnd hook: Generate a structured experiment summary when the Claude session ends.

Receives JSON on stdin: {"transcript_path": "/path/to/session.jsonl"}

Reads the session transcript to extract:
  - Experiment directories created/touched
  - Training runs detected (python train*.py calls + their outputs)
  - Accuracy / metric numbers found in output
  - Files written (plan.md, critique.md, literature_notes.md)
  - Key decisions noted

Writes: {exp_root}/session_summary.md  (appends if exists)

Also prints a brief summary to stderr so Claude sees it before the session closes.
"""

import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path


# ── Patterns ──────────────────────────────────────────────────────────────────

TRAINING_CMD_RE = re.compile(
    r'python\s+.*train|torchrun\b|accelerate\s+launch|deepspeed\b'
    r'|python\s+-m\s+(trl|transformers)\s+|llamafactory-cli\s+train'
    r'|python\s+.*finetune|python\s+.*sft|python\s+.*dpo|python\s+.*grpo',
    re.IGNORECASE,
)

METRIC_RE = re.compile(
    r'(?:'
    r'(?:accuracy|acc|exact[\s_-]?match|em)\s*[=:]\s*([\d.]+%?)'
    r'|(?:loss)\s*[=:]\s*([\d.]+)'
    r'|(?:score|f1|bleu|rouge)\s*[=:]\s*([\d.]+%?)'
    r')',
    re.IGNORECASE,
)

PIPELINE_FILES = {'literature_notes.md', 'plan.md', 'critique.md', 'REPORT.md'}

EXPERIMENT_DIR_RE = re.compile(
    r'(?:mkdir|cd|Created|Writing to|Saving)\s+["\']?'
    r'([\w./-]*(?:experiment|run_|exp_|trial_|checkpoint|final_model)[^\s"\']*)',
    re.IGNORECASE,
)


# ── Transcript parsing ─────────────────────────────────────────────────────────

def parse_transcript(transcript_path: str) -> dict:
    """Parse a Claude Code JSONL transcript and extract experiment-relevant data."""
    result = {
        'training_runs': [],    # list of {cmd, metrics, run_dir}
        'pipeline_files': [],   # literature_notes, plan, critique files written
        'experiment_dirs': set(),
        'all_metrics': [],
        'user_messages': [],
        'bash_commands': [],
    }

    if not os.path.exists(transcript_path):
        return result

    with open(transcript_path, 'r', encoding='utf-8', errors='replace') as f:
        lines = f.readlines()

    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue

        # Collect user messages
        role = entry.get('role') or entry.get('type', '')
        if role == 'user':
            content = entry.get('content', '')
            if isinstance(content, str) and content.strip():
                result['user_messages'].append(content.strip()[:300])
            elif isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get('type') == 'text':
                        result['user_messages'].append(block.get('text', '')[:300])

        # Walk assistant message content blocks (tool_use)
        if role in ('assistant', 'tool_use') or entry.get('type') == 'assistant':
            content_blocks = (
                entry.get('message', {}).get('content', [])
                if 'message' in entry
                else entry.get('content', [])
            )
            if isinstance(content_blocks, list):
                for block in content_blocks:
                    if not isinstance(block, dict):
                        continue
                    if block.get('type') == 'tool_use':
                        _process_tool_use(block, result)

        # Also handle flat tool_use entries
        if entry.get('type') == 'tool_use' or entry.get('tool_name'):
            _process_tool_use(entry, result)

    return result


def _process_tool_use(block: dict, result: dict):
    name = block.get('name') or block.get('tool_name', '')
    inp = block.get('input') or block.get('tool_input') or {}
    out_text = ''
    out = block.get('tool_output') or block.get('output') or {}
    if isinstance(out, dict):
        out_text = out.get('output', '') or ''
    elif isinstance(out, str):
        out_text = out

    # Bash tool
    if name == 'Bash':
        cmd = inp.get('command', '')
        result['bash_commands'].append(cmd[:200])
        if TRAINING_CMD_RE.search(cmd):
            metrics = extract_metrics(out_text)
            run_dir = guess_run_dir(cmd, out_text)
            result['training_runs'].append({
                'cmd': cmd[:150],
                'metrics': metrics,
                'run_dir': run_dir,
            })
            result['all_metrics'].extend(metrics)

        # Experiment dir hints
        for m in EXPERIMENT_DIR_RE.finditer(cmd + ' ' + out_text):
            d = m.group(1).strip('/')
            if d:
                result['experiment_dirs'].add(d)

    # Write/Edit tool — pipeline file tracking
    if name in ('Write', 'Edit'):
        fp = inp.get('file_path', '')
        basename = os.path.basename(fp)
        if basename in PIPELINE_FILES:
            result['pipeline_files'].append(fp)


def extract_metrics(text: str) -> list[str]:
    found = []
    for m in METRIC_RE.finditer(text):
        val = m.group(1) or m.group(2) or m.group(3)
        metric_name = m.group(0).split('=')[0].split(':')[0].strip()
        found.append(f'{metric_name}: {val}')
    # De-dup while preserving order
    seen = set()
    deduped = []
    for item in found:
        if item not in seen:
            seen.add(item)
            deduped.append(item)
    return deduped[:8]


def guess_run_dir(cmd: str, output: str) -> str:
    # Look for "run_XXX" pattern in command or output
    m = re.search(r'\b(run_\w+|checkpoint[-_]\w+)\b', cmd + ' ' + output, re.IGNORECASE)
    return m.group(1) if m else ''


# ── Summary writing ────────────────────────────────────────────────────────────

def find_exp_dir() -> Path:
    """Find the experiment output directory (claude/ or codex/ subdir of exp/)."""
    cwd = Path.cwd()
    # If we're already inside an exp subdir, use cwd
    if (cwd / 'plan.md').exists() or (cwd / 'literature_notes.md').exists():
        return cwd
    # Look for the most recently modified experiment subdir
    for candidate in ['claude', 'codex']:
        p = cwd / candidate
        if p.is_dir():
            subdirs = sorted(p.iterdir(), key=lambda x: x.stat().st_mtime, reverse=True)
            for s in subdirs:
                if s.is_dir():
                    return s
    return cwd


def write_summary(data: dict, output_path: Path):
    now = datetime.now().strftime('%Y-%m-%d %H:%M')
    lines = [
        f'# Session Summary — {now}',
        '',
    ]

    # Training runs
    if data['training_runs']:
        lines += ['## Training Runs', '']
        for i, run in enumerate(data['training_runs'], 1):
            lines.append(f'### Run {i}')
            lines.append(f'- **Command**: `{run["cmd"]}`')
            if run['run_dir']:
                lines.append(f'- **Run dir**: `{run["run_dir"]}`')
            if run['metrics']:
                lines.append(f'- **Metrics**: {", ".join(run["metrics"])}')
            else:
                lines.append('- **Metrics**: (none detected in output)')
            lines.append('')
    else:
        lines += ['## Training Runs', '', '_(no training commands detected)_', '']

    # Pipeline files written
    if data['pipeline_files']:
        lines += ['## Pipeline Files Written', '']
        for fp in sorted(set(data['pipeline_files'])):
            lines.append(f'- `{fp}`')
        lines.append('')

    # All metrics across session
    if data['all_metrics']:
        lines += ['## Metrics Observed', '']
        for m in data['all_metrics'][:12]:
            lines.append(f'- {m}')
        lines.append('')

    lines += [
        '---',
        '',
    ]

    summary_text = '\n'.join(lines)

    # Append to file if it exists (sessions accumulate), else create
    if output_path.exists():
        with open(output_path, 'a', encoding='utf-8') as f:
            f.write('\n' + summary_text)
    else:
        output_path.write_text(summary_text, encoding='utf-8')

    return summary_text


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    # Read stdin (Claude Code passes {"transcript_path": "..."})
    stdin_data = sys.stdin.read().strip()
    transcript_path = None
    if stdin_data:
        try:
            inp = json.loads(stdin_data)
            transcript_path = inp.get('transcript_path')
        except json.JSONDecodeError:
            pass

    if not transcript_path:
        # Nothing to do without a transcript
        sys.exit(0)

    data = parse_transcript(transcript_path)

    # Find where to write the summary
    exp_dir = find_exp_dir()
    output_path = exp_dir / 'session_summary.md'

    summary = write_summary(data, output_path)

    # Print a brief digest to stderr — Claude sees this before session closes
    run_count = len(data['training_runs'])
    metric_count = len(data['all_metrics'])
    print(f'\n[SessionEnd Hook] Summary written → {output_path}', file=sys.stderr)
    print(
        f'[SessionEnd Hook] {run_count} training run(s) detected, '
        f'{metric_count} metric(s) captured.',
        file=sys.stderr,
    )
    if data['all_metrics']:
        print(f'[SessionEnd Hook] Metrics: {", ".join(data["all_metrics"][:4])}', file=sys.stderr)

    sys.exit(0)


if __name__ == '__main__':
    main()
