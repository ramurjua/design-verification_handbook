#!/usr/bin/env python3
"""Benchmark: Claude answering waveform questions with and without the WAL skill.

Every question in questions.json is sent to a fresh, non-interactive Claude Code
session (`claude -p`), once per model and per arm:

  wal     the skill text (../skill/SKILL.md) is given to Claude, and it must use
          ../skill/scripts/wal_run.py for every waveform access
  nowal   anything except WAL (Claude usually writes its own VCD parser)

Each session runs with --safe-mode (no user skills, CLAUDE.md, memory or plugins),
so the only difference between the arms is the skill. The answer comes back as JSON
(--json-schema) and is graded against golden.json. Time, cost and turns come from
Claude Code's own JSON result.

  python run_bench.py                               # all questions, haiku/sonnet/opus, both arms
  python run_bench.py --models sonnet --questions E1,D3 --arms wal
  python run_bench.py --dry-run                     # print the commands, spend nothing
  python run_bench.py --regrade results/<run>       # grade saved answers again (after editing golden.json)
  python run_bench.py --arms wal --reuse results/<run> --update-md   # after a skill change: new WAL rows,
                                                    # no-WAL rows taken from the earlier run
  python run_bench.py ... --update-md               # also put the tables into ../waveforms_analysis.md

Output: results/<timestamp>/ with raw/<model>__<arm>__<qid>.json (Claude's full JSON
result plus the grade), results.json and report.md. report.md ends with the models'
notes and the failed checks: that is the input for improving the skill.

Requirements: Claude Code (`claude` on PATH, logged in), Python 3.9+, wal-lang
(python -m pip install wal-lang). The VCD files must exist (see questions.json).
Cost: one session per question x model x arm; check with --dry-run first and cap
each session with --max-budget-usd.
"""

import argparse
import concurrent.futures as cf
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.normpath(os.path.join(HERE, '..', 'skill'))
REPO = os.path.normpath(os.path.join(HERE, '..', '..', '..'))
MD_PATH = os.path.normpath(os.path.join(HERE, '..', 'waveforms_analysis.md'))
MD_START, MD_END = '<!-- BENCH:START -->', '<!-- BENCH:END -->'

ALLOWED_TOOLS = 'Bash PowerShell Read Glob Grep Write'  # no Edit: the repository stays untouched
DENIED_TOOLS = 'Agent WebFetch WebSearch Skill'   # no subagents, no web, no installed skills

PROMPT = """You are answering one question about a digital simulation waveform (VCD file).

Repository root (read-only, do not modify anything there, do not re-run simulations): {repo}
Waveform: {wave} ({about})
Your scratch directory (current directory; put any files you create here): {scratch}

Conventions: {conventions}

Question {qid}: {text}

{method}

Answer with the requested JSON. In "notes", write one to three sentences on anything that was \
ambiguous, awkward or uncertain while answering (method problems, interpretation choices); \
write "none" if nothing was."""

METHOD = {
    'wal': ("Method: use WAL as described in the skill in your system prompt. Every access to the "
            "waveform must go through {script}; do not read, grep or parse the VCD file in any other way "
            "and do not write your own VCD parser."),
    'nowal': ("Method: anything except WAL. Do not use the wal-lang Python package, wal_run.py or "
              "anything under {skill}. Use whatever approach you would normally choose."),
}


# ---------------------------------------------------------------- grading

def _num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def _hex(s):
    s = s.strip().lower()
    s = s[2:] if s.startswith('0x') else s
    return int(s, 16) if re.fullmatch(r'[0-9a-f]+', s) else None


def compare(gold, got, path, tol, keyed, errors):
    """Append a message to errors for every mismatch between gold and got."""
    if isinstance(gold, dict):
        if not isinstance(got, dict):
            errors.append(f'{path}: expected an object, got {got!r}')
            return
        for k, v in gold.items():
            if k not in got:
                errors.append(f'{path}.{k}: missing')
            else:
                compare(v, got[k], f'{path}.{k}', tol, keyed, errors)
    elif isinstance(gold, list):
        if not isinstance(got, list):
            errors.append(f'{path}: expected a list, got {got!r}')
            return
        key = keyed.get(path.split('.')[-1])
        if key:
            by_key = {str(item.get(key)).strip().lower(): item for item in got if isinstance(item, dict)}
            for item in gold:
                k = str(item[key]).lower()
                if k not in by_key:
                    errors.append(f'{path}[{key}={k}]: missing')
                else:
                    compare(item, by_key[k], f'{path}[{key}={k}]', tol, keyed, errors)
        else:
            if len(gold) != len(got):
                errors.append(f'{path}: {len(got)} items, expected {len(gold)}')
            for i, (a, b) in enumerate(zip(gold, got)):
                compare(a, b, f'{path}[{i}]', tol, keyed, errors)
    elif isinstance(gold, bool):
        if got is not gold:
            errors.append(f'{path}: {got!r}, expected {gold!r}')
    elif _num(gold):
        if not _num(got) or abs(got - gold) > tol:
            errors.append(f'{path}: {got!r}, expected {gold!r}')
    elif isinstance(gold, str):
        ok = isinstance(got, str) and (got.strip().lower() == gold.lower() or
                                        (_hex(gold) is not None and _hex(got) == _hex(gold)))
        if not ok:
            errors.append(f'{path}: {got!r}, expected {gold!r}')


def grade(qid, answer, golden):
    g = golden['answers'][qid]
    if not isinstance(answer, dict):
        return False, ['no structured answer']
    errors = []
    compare(g['answer'], answer, qid, g.get('abs_tol', 0.01), g.get('keyed_lists', {}), errors)
    return not errors, errors


# ---------------------------------------------------------------- running claude

def skill_prompt():
    """The skill text as handed to the 'wal' arm, with SKILL_DIR made concrete."""
    with open(os.path.join(SKILL_DIR, 'SKILL.md'), encoding='utf-8') as f:
        text = f.read()
    text = re.sub(r'^---.*?---\s*', '', text, flags=re.S)  # drop front matter
    skill = SKILL_DIR.replace('\\', '/')
    text = text.replace('~/.claude/skills/wal', skill).replace('$HOME\\.claude\\skills\\wal', SKILL_DIR)
    text = text.replace('SKILL_DIR', skill)
    # The skill runs as a forked agent that receives its task as $ARGUMENTS; here the task is the user message.
    text = text.replace('$ARGUMENTS', '(the question in the user message; answer it in the JSON format requested there)')
    return ('The following skill is available for this task. Its folder is ' + skill +
            ' (reference.md and scripts/wal_run.py are there).\n\n' + text)


def build_cmd(q, model, arm, scratch, args, questions):
    wave = questions['waveforms'][q['waveform']]
    schema = {'type': 'object', 'properties': dict(q['schema'], notes={'type': 'string'}),
              'required': list(q['schema']) + ['notes'], 'additionalProperties': False}
    method = METHOD[arm].format(script=os.path.join(SKILL_DIR, 'scripts', 'wal_run.py'), skill=SKILL_DIR)
    prompt = PROMPT.format(repo=REPO, wave=os.path.join(REPO, wave['path']), about=wave['about'],
                           scratch=scratch, conventions=questions['conventions'], qid=q['id'],
                           text=q['text'], method=method)
    cmd = [args.claude, '-p', prompt, '--model', model, '--output-format', 'json',
           '--json-schema', json.dumps(schema), '--safe-mode', '--no-session-persistence',
           '--add-dir', REPO, '--allowedTools', ALLOWED_TOOLS, '--disallowedTools', DENIED_TOOLS,
           '--max-budget-usd', str(args.max_budget_usd)]
    if args.effort:
        cmd += ['--effort', args.effort]
    if arm == 'wal':
        cmd += ['--append-system-prompt', skill_prompt()]
    return cmd


def run_one(q, model, arm, args, questions, golden, raw_dir, log):
    name = f'{model}__{arm}__{q["id"]}'
    scratch = tempfile.mkdtemp(prefix=f'wal_bench_{name}_')
    cmd = build_cmd(q, model, arm, scratch, args, questions)
    t0 = time.time()
    try:
        p = subprocess.run(cmd, cwd=scratch, capture_output=True, text=True, encoding='utf-8',
                           errors='replace', timeout=args.timeout)
        out, err, rc = p.stdout, p.stderr, p.returncode
    except subprocess.TimeoutExpired:
        out, err, rc = '', f'timeout after {args.timeout} s', -1
    wall = time.time() - t0
    try:
        res = json.loads(out)
    except ValueError:
        res = {'is_error': True, 'result': out[-2000:]}
    answer = res.get('structured_output')
    ok, errors = grade(q['id'], answer, golden)
    # The session itself failed (usage limit, API error, timeout, crash): not a wrong answer.
    session_error = answer is None and (res.get('is_error') or rc != 0 or res.get('terminal_reason') == 'api_error')
    if session_error:
        errors = ['session error: ' + str(res.get('result') or err or f'exit {rc}')[:200]]
    rec = {'model': model, 'arm': arm, 'qid': q['id'], 'level': q['level'], 'ok': ok, 'errors': errors,
           'session_error': bool(session_error),
           'answer': answer, 'wall_s': round(wall, 1), 'duration_ms': res.get('duration_ms'),
           'cost_usd': res.get('total_cost_usd'), 'num_turns': res.get('num_turns'),
           'is_error': res.get('is_error', rc != 0), 'returncode': rc, 'stderr': err[-2000:],
           'claude_result': res}
    with open(os.path.join(raw_dir, name + '.json'), 'w', encoding='utf-8') as f:
        json.dump(rec, f, indent=1)
    shutil.rmtree(scratch, ignore_errors=True)
    log(f'{name}: {"PASS" if ok else "ERROR" if session_error else "FAIL"}  {wall:.0f} s  ${rec["cost_usd"] or 0:.3f}'
        + ('' if ok else f'  ({"; ".join(errors[:2])})'))
    return rec


# ---------------------------------------------------------------- report

def fmt_cost(x):
    return f'${x:.2f}' if x is not None else '?'


def make_report(recs, questions, meta):
    qs = [q['id'] for q in questions['questions'] if any(r['qid'] == q['id'] for r in recs)]
    level = {q['id']: q['level'] for q in questions['questions']}
    combos = sorted({(r['model'], r['arm']) for r in recs}, key=lambda c: (c[0], c[1] != 'wal'))
    by = {(r['model'], r['arm'], r['qid']): r for r in recs}
    arm_name = {'wal': 'with WAL skill', 'nowal': 'without'}

    reused = sorted({(r['model'], r['arm']) for r in recs if r.get('reused')})
    note = (f' Rows {", ".join(f"{m} {arm_name.get(a, a)}" for m, a in reused)} are reused from run '
            f'{meta.get("reused_from")}.') if reused else ''
    lines = [f'Run {meta["run"]}: Claude Code {meta["claude_version"]}, effort {meta["effort"] or "default"}, '
             f'{len(qs)} questions, one fresh session per question.{note}', '',
             '| Model | Method | Easy | Difficult | Total | Time (s) | Cost | Avg turns |',
             '|---|---|---|---|---|---|---|---|']
    for m, a in combos:
        rs = [by[(m, a, q)] for q in qs if (m, a, q) in by]
        easy = [r for r in rs if level[r['qid']] == 'easy']
        diff = [r for r in rs if level[r['qid']] != 'easy']
        cost = sum(r['cost_usd'] or 0 for r in rs)
        turns = [r['num_turns'] for r in rs if r['num_turns']]
        lines.append(f'| {m} | {arm_name.get(a, a)} | {sum(r["ok"] for r in easy)}/{len(easy)} | '
                     f'{sum(r["ok"] for r in diff)}/{len(diff)} | **{sum(r["ok"] for r in rs)}/{len(rs)}**'
                     + (f' ({n_err} session errors)' if (n_err := sum(r.get('session_error', False) for r in rs)) else '')
                     + ' | '
                     f'{sum(r["wall_s"] for r in rs):.0f} | {fmt_cost(cost)} | '
                     f'{(sum(turns) / len(turns)) if turns else 0:.1f} |')
    lines += ['', 'Per question (✓/✗, wall-clock seconds, cost):', '',
              '| Question | ' + ' | '.join(f'{m} {"WAL" if a == "wal" else "no WAL"}' for m, a in combos) + ' |',
              '|---|' + '---|' * len(combos)]
    for q in qs:
        cells = []
        for m, a in combos:
            r = by.get((m, a, q))
            mark = '–' if r is None else '✓' if r['ok'] else 'error' if r.get('session_error') else '✗'
            cells.append(mark if r is None else f'{mark} {r["wall_s"]:.0f} s {fmt_cost(r["cost_usd"])}')
        lines.append(f'| {q} ({level[q]}) | ' + ' | '.join(cells) + ' |')
    tables = '\n'.join(lines)

    detail = ['', '## Failed checks', '']
    fails = [r for r in recs if not r['ok']]
    detail += [f'- **{r["model"]} {r["arm"]} {r["qid"]}**: ' + '; '.join(r['errors'][:5]) for r in fails] or ['None.']
    detail += ['', '## Notes from the models (input for improving the skill)', '']
    for r in sorted(recs, key=lambda r: (r['arm'], r['qid'], r['model'])):
        note = (r['answer'] or {}).get('notes') if isinstance(r['answer'], dict) else None
        if note and note.strip().lower() not in ('none', 'none.', ''):
            detail.append(f'- {r["arm"]} / {r["model"]} / {r["qid"]}: {note.strip()}')
    return tables, '# WAL benchmark report\n\n' + tables + '\n' + '\n'.join(detail) + '\n'


def reuse_results(old_dir, running, qids, golden, raw_dir):
    """Copy (and re-grade) results of an earlier run for the model/method pairs not run now."""
    recs = []
    old_raw = os.path.join(os.path.abspath(old_dir), 'raw')
    for name in sorted(os.listdir(old_raw)):
        with open(os.path.join(old_raw, name), encoding='utf-8') as f:
            r = json.load(f)
        if (r['model'], r['arm']) in running or r['qid'] not in qids:
            continue
        if not r.get('session_error'):  # a session error stays an error; re-grading cannot fix it
            r['ok'], r['errors'] = grade(r['qid'], r['answer'], golden)
        r['reused'] = True
        with open(os.path.join(raw_dir, name), 'w', encoding='utf-8') as f:
            json.dump(r, f, indent=1)
        recs.append(r)
    print(f'reused {len(recs)} results from {old_dir}')
    return recs


def update_md(tables):
    with open(MD_PATH, encoding='utf-8') as f:
        md = f.read()
    if MD_START not in md or MD_END not in md:
        print(f'! {MD_PATH} has no {MD_START} / {MD_END} markers; not updated')
        return
    head, rest = md.split(MD_START, 1)
    _, tail = rest.split(MD_END, 1)
    with open(MD_PATH, 'w', encoding='utf-8') as f:
        f.write(head + MD_START + '\n' + tables + '\n' + MD_END + tail)
    print(f'updated {MD_PATH}')


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument('--models', default='haiku,sonnet,opus', help='comma-separated --model values')
    ap.add_argument('--arms', default='wal,nowal')
    ap.add_argument('--questions', default='', help='comma-separated ids; default all')
    ap.add_argument('--jobs', type=int, default=3, help='sessions in parallel')
    ap.add_argument('--effort', default='', help='low|medium|high|xhigh|max; default: the model default')
    ap.add_argument('--timeout', type=int, default=1200, help='seconds per session')
    ap.add_argument('--max-budget-usd', type=float, default=2.0, help='cap per session')
    ap.add_argument('--claude', default=shutil.which('claude') or 'claude')
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--regrade', metavar='RUN_DIR', help='re-grade a previous run, no new sessions')
    ap.add_argument('--update-md', action='store_true', help=f'write the tables into {MD_PATH}')
    ap.add_argument('--force', action='store_true', help='with --update-md: write the table even with session errors')
    ap.add_argument('--reuse', metavar='RUN_DIR',
                    help='take the results of model/method pairs not run now from an earlier run '
                         '(e.g. re-run only --arms wal after a skill change, keep the no-WAL rows)')
    args = ap.parse_args()
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')  # the tables use ✓/✗

    with open(os.path.join(HERE, 'questions.json'), encoding='utf-8') as f:
        questions = json.load(f)
    with open(os.path.join(HERE, 'golden.json'), encoding='utf-8') as f:
        golden = json.load(f)
    wanted = [s.strip() for s in args.questions.split(',') if s.strip()]
    qlist = [q for q in questions['questions'] if not wanted or q['id'] in wanted]

    if args.regrade:
        run_dir = os.path.abspath(args.regrade)
        recs = []
        for name in sorted(os.listdir(os.path.join(run_dir, 'raw'))):
            with open(os.path.join(run_dir, 'raw', name), encoding='utf-8') as f:
                r = json.load(f)
            if not r.get('session_error'):
                r['ok'], r['errors'] = grade(r['qid'], r['answer'], golden)
            recs.append(r)
        with open(os.path.join(run_dir, 'results.json'), encoding='utf-8') as f:
            meta = json.load(f)['meta']
    else:
        for q in qlist:
            if not os.path.isfile(os.path.join(REPO, questions['waveforms'][q['waveform']]['path'])):
                print(f'! missing waveform for {q["id"]}: run its testbench first')
                return 2
        models = [m.strip() for m in args.models.split(',') if m.strip()]
        arms = [a.strip() for a in args.arms.split(',') if a.strip()]
        jobs = [(q, m, a) for m in models for a in arms for q in qlist]
        if args.dry_run:
            for q, m, a in jobs[:1]:
                cmd = build_cmd(q, m, a, '<scratch>', args, questions)
                print(' '.join(c if len(c) < 200 else c[:200] + '...' for c in cmd))
            print(f'{len(jobs)} sessions: {len(qlist)} questions x {models} x {arms}; '
                  f'worst case ${len(jobs) * args.max_budget_usd:.0f} with --max-budget-usd {args.max_budget_usd}')
            return 0
        version = subprocess.run([args.claude, '--version'], capture_output=True, text=True).stdout.split()[0]
        run = dt.datetime.now().strftime('%Y%m%d-%H%M%S')
        run_dir = os.path.join(HERE, 'results', run)
        os.makedirs(os.path.join(run_dir, 'raw'))
        meta = {'run': run, 'claude_version': version, 'effort': args.effort, 'models': models, 'arms': arms}
        lock = threading.Lock()

        def log(msg):
            with lock:
                print(msg, flush=True)

        print(f'{len(jobs)} sessions, {args.jobs} at a time -> {run_dir}')
        with cf.ThreadPoolExecutor(args.jobs) as ex:
            recs = list(ex.map(lambda j: run_one(*j, args, questions, golden,
                                                 os.path.join(run_dir, 'raw'), log), jobs))
        if args.reuse:
            recs += reuse_results(args.reuse, {(m, a) for _, m, a in jobs}, {q['id'] for q in qlist},
                                  golden, os.path.join(run_dir, 'raw'))
            meta['reused_from'] = os.path.basename(os.path.normpath(args.reuse))

    tables, report = make_report(recs, questions, meta)
    slim = [{k: v for k, v in r.items() if k != 'claude_result'} for r in recs]
    with open(os.path.join(run_dir, 'results.json'), 'w', encoding='utf-8') as f:
        json.dump({'meta': meta, 'results': slim}, f, indent=1)
    with open(os.path.join(run_dir, 'report.md'), 'w', encoding='utf-8') as f:
        f.write(report)
    print('\n' + tables + f'\n\nreport: {os.path.join(run_dir, "report.md")}')
    n_err = sum(r.get('session_error', False) for r in recs)
    if n_err:
        print(f'! {n_err} sessions ended in an error (usage limit, API error, timeout), not a wrong answer: '
              'see report.md. Re-run those (e.g. with --reuse) before publishing the table.')
    if args.update_md and n_err and not args.force:
        print('! table NOT written to the note because of session errors (use --force to write it anyway)')
    elif args.update_md:
        update_md(tables)
    return 1 if n_err else 0


if __name__ == '__main__':
    sys.exit(main())
