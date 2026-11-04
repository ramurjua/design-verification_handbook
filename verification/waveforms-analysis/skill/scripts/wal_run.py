#!/usr/bin/env python3
"""Run WAL (Waveform Analysis Language) queries on VCD/FST/CSV waveforms.

A thin wrapper around the `wal-lang` package (https://github.com/ics-jku/wal)
so that waveforms are queried, never read raw. It loads the waveform(s) once,
runs any number of WAL expressions/files in order and prints compact results.

  python wal_run.py WAVE [WAVE ...] [options]

  --info                 file, timescale, time range, scopes, signal count
  --signals [PATTERN]    list signals (with widths) matching a glob; no '*' means "contains"
  -e EXPR                evaluate WAL expression(s); repeatable, run in order
  -f FILE.wal            evaluate a WAL file; repeatable, run in order with -e;
                         -f - reads the program from stdin (a quoted heredoc avoids shell quoting)
  --table PAT [PAT ...]  value table of the matching signals, one row per change
      --from T --to T    time window (e.g. 12.5us, 300ns, 1200 = raw timescale units)
      --edges CLK        one row per rising edge of CLK instead of per change
                         (values just before the edge, i.e. what flip-flops sample)
      --max-rows N       default 100
  --setup FILE.wal       project setup (aliases, defsig, helpers); default: the nearest
                         wal_setup.wal from the waveform's folder up to the repo root
  --no-setup             do not load any setup file
  --keep PAT [PAT ...]   load only signals matching these globs (VCD only, faster on big files)
  --max-items N          truncate printed lists to N items (default 50)
  --max-lines N          truncate printed output of one expression to N lines (default 200)

One waveform is loaded as trace id t0 and its signals are used by full name
(tb.dut.sig). With several waveforms (t0, t1, ...) signals are t0^tb.sig, t1^tb.sig.

Defined before anything runs:
  TIMESCALE-PS     picoseconds per TS unit of the first waveform
  (at i expr)      evaluate expr at absolute index i, e.g. (at 622 TS)
  (ts->ns t)       raw timestamp -> nanoseconds (float); (ns->ts ns) the other way
  (index-at t)     last index with timestamp <= t (raw units): value lookup by time
  (at-ns ns expr)  evaluate expr at time ns, e.g. (at-ns 1250.5 tb.w_tx)
Fast helpers (one Python pass over a signal instead of WAL evaluating at every index;
same indices as the equivalent find, never a phantom edge at MAX-INDEX):
  (rising-edges 'sig) (falling-edges 'sig) (changes 'sig)    lists of indices
  (values-at idxs 'sig)      value of sig at each index, e.g. (values-at (map (fn [i] (+ i 1)) e) 'tb.data)
  (times-ns idxs [offset])   time in ns of each index; offset 1 gives edge times
  (rising-times-ns 'sig) (falling-times-ns 'sig)            edge times in ns directly
  (hex v [digits])           int (or list of ints) -> hex text, e.g. (hex 1389860 6) = "153524"
A result that is None (or a list of only None) is not printed.
Vectors containing x/z bits are returned as strings such as "10xz" instead of
raising (WAL itself raises a Python ValueError on them); scalar x/z are "x"/"z".

Exit code: 0 if every expression evaluated, 1 if any failed, 2 on a usage/load error.
"""

import argparse
import bisect
import contextlib
import fnmatch
import io
import os
import re
import sys

try:
    from wal.core import Wal
    from wal.reader import read_wal_sexprs, ParseError
    from wal.ast_defs import WalEvalError
    from wal.util import wal_str
    from wal.trace.vcd import TraceVcd
except ImportError:
    print('wal-lang is not installed: python -m pip install wal-lang', file=sys.stderr)
    sys.exit(2)


# Helpers defined before the setup file and the user's expressions.
PRELUDE = r'''
(defmacro at [i expr] `(reval ,expr (- ,i INDEX)))
(defun ts->ns [t] (/ (* t TIMESCALE-PS) 1000.0))
(defun ns->ts [ns] (/ (* ns 1000.0) TIMESCALE-PS))
(defmacro at-ns [ns expr] `(at (index-at (ns->ts ,ns)) ,expr))
'''

UNITS_PS = {'fs': 1e-3, 'ps': 1, 'ns': 1e3, 'us': 1e6, 'ms': 1e9, 's': 1e12}


# ---------------------------------------------------------------- WAL patches

_orig_access = TraceVcd.access_signal_data


def _access_signal_data(self, name, index):
    """Like WAL's, but a vector with x/z bits comes back as a string instead of raising."""
    try:
        return _orig_access(self, name, index)
    except ValueError:
        value = self.data[name][self.lookup[index] if self.lookup else index]
        return value[1:].lower() if value[:1] in ('b', 'B') else value


TraceVcd.access_signal_data = _access_signal_data


# ---------------------------------------------------------------- helpers

def timescale_ps(trace):
    """Picoseconds per timestamp unit of a trace (1 if unknown)."""
    txt = getattr(trace, 'timescale', None)
    if not txt:
        return 1
    m = re.fullmatch(r'\s*(\d+)\s*([fpnum]?s)\s*', str(txt))
    if not m:
        return 1
    value = int(m.group(1)) * UNITS_PS[m.group(2)]
    return int(value) if value == int(value) else value


def fmt_time(ts, scale_ps):
    """Human readable time for a raw timestamp."""
    ps = ts * scale_ps
    for unit in ('s', 'ms', 'us', 'ns'):
        if abs(ps) >= UNITS_PS[unit]:
            return f'{ps / UNITS_PS[unit]:.6g}{unit}'
    return f'{ps:.6g}ps'


def parse_time(txt, scale_ps):
    """'12.5us' / '300ns' -> raw timestamp units; a bare number is already raw units."""
    m = re.fullmatch(r'\s*([0-9.eE+-]+)\s*([fpnum]?s)?\s*', txt)
    if not m:
        raise ValueError(f'bad time "{txt}" (use e.g. 1200, 300ns, 12.5us)')
    value = float(m.group(1))
    if m.group(2):
        value = value * UNITS_PS[m.group(2)] / scale_ps
    return value


def glob_match(name, pattern):
    """Case-insensitive glob; a pattern without wildcards matches as a substring."""
    if not any(c in pattern for c in '*?['):
        pattern = f'*{pattern}*'
    return fnmatch.fnmatchcase(name.lower(), pattern.lower())


def vcd_names_matching(path, patterns):
    """Full signal names in a VCD header that match any pattern (same mangling as WAL)."""
    names, scope = [], []
    with open(path, encoding='utf-8', errors='replace') as f:
        tokens = []
        for line in f:
            tokens += line.split()
            if '$enddefinitions' in tokens:
                break
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok == '$scope':
            scope.append(re.sub(r'[\[(]([0-9]+)[\])]', r'<\1>', tokens[i + 2]))
            i += 4
        elif tok == '$upscope':
            scope.pop()
            i += 2
        elif tok == '$var':
            name = re.sub(r'\[[0-9]+:[0-9]+\]', '', tokens[i + 4])
            name = re.sub(r'[\[(]([0-9]+)[\])]', r'<\1>', name)
            full = '.'.join(scope + [name])
            if any(glob_match(full, p) for p in patterns):
                names.append(full)
            i += 5
        else:
            i += 1
    return names


def find_setup(wave_path):
    """Nearest wal_setup.wal from the waveform's folder upwards, stopping at a repo root."""
    folder = os.path.dirname(os.path.abspath(wave_path))
    while True:
        candidate = os.path.join(folder, 'wal_setup.wal')
        if os.path.isfile(candidate):
            return candidate
        parent = os.path.dirname(folder)
        if os.path.isdir(os.path.join(folder, '.git')) or parent == folder:
            return None
        folder = parent


def fmt_value(value, max_items):
    if isinstance(value, (list, tuple)) or type(value).__name__ == 'WList':
        items = list(value)
        shown = ' '.join(fmt_value(v, max_items) for v in items[:max_items])
        more = f' ... ({len(items) - max_items} more, {len(items)} total)' if len(items) > max_items else ''
        return f'({shown}{more})'
    if isinstance(value, str):
        return f'"{value}"'
    if value is True:
        return '#t'
    if value is False:
        return '#f'
    try:
        return wal_str(value)
    except Exception:  # pylint: disable=broad-except
        return repr(value)


def cap_lines(text, max_lines):
    lines = text.rstrip('\n').split('\n') if text.strip() else []
    if len(lines) > max_lines:
        lines = lines[:max_lines] + [f'... ({len(lines) - max_lines} more lines)']
    return lines


# ---------------------------------------------------------------- fast helpers

def fast_operators(wal):
    """WAL operators implemented in Python over the loaded value lists.

    They return the same indices as the equivalent (find ...) but scan a signal in
    one Python pass instead of interpreting an expression at every index, which is
    10-100x faster on large traces. Index convention as in WAL: an edge is reported
    at the index *before* the change (so TS@1 is its time, sig@1 the new value);
    the last index is never reported, so there are no phantom edges at MAX-INDEX.
    """

    def resolve(seval, arg):
        """Signal argument (quoted symbol or string, alias allowed) -> (trace, name)."""
        val = seval.eval(arg)
        name = val if isinstance(val, str) else getattr(val, 'name', None)
        assert isinstance(name, str), 'expected a quoted signal name, e.g. \'tb.clk or "tb.clk"'
        name = seval.aliases.get(name, name)
        traces = wal.traces.traces
        if '^' in name:
            tid, name = name.split('^', 1)
            trace = traces[tid]
        else:
            trace = next(iter(traces.values()))
        assert name in getattr(trace, 'data', {}), f'no signal "{name}" (fast helpers need a real VCD signal)'
        return trace, name

    def values(trace, name):
        data = trace.data[name]
        if trace.lookup:  # after (sample-at ...): follow WAL's index translation
            return [data[trace.lookup[i]] for i in range(trace.max_index + 1)]
        return data[:trace.max_index + 1]

    def bit(v):
        return v[-1] if v[:1] in ('b', 'B') and len(v) == 2 else (v if v in ('0', '1') else None)

    def op_changes(seval, args):
        """(changes 'sig): indices i where sig@1 differs from sig (any change, x/z included)."""
        trace, name = resolve(seval, args[0])
        v = values(trace, name)
        return [i for i in range(len(v) - 1) if v[i] != v[i + 1]]

    def make_edge(old, new):
        def op_edge(seval, args):
            trace, name = resolve(seval, args[0])
            v = [bit(x) for x in values(trace, name)]
            return [i for i in range(len(v) - 1) if v[i] == old and v[i + 1] == new]
        return op_edge

    def op_values_at(seval, args):
        """(values-at idxs 'sig): the value of sig at each index of the list (ints; x/z as strings)."""
        idxs = seval.eval(args[0])
        trace, name = resolve(seval, args[1])
        last = trace.max_index
        return [trace.access_signal_data(name, min(i, last)) for i in idxs]

    def op_times_ns(seval, args):
        """(times-ns idxs) or (times-ns idxs 1): timestamp in ns of each index (+ offset, e.g. 1 for edge times)."""
        idxs = seval.eval(args[0])
        off = seval.eval(args[1]) if len(args) > 1 else 0
        trace = next(iter(wal.traces.traces.values()))
        scale = timescale_ps(trace) / 1000.0
        last = trace.max_index
        return [trace.timestamps[min(i + off, last)] * scale for i in idxs]

    def make_edge_times(old, new):
        edge = make_edge(old, new)

        def op_edge_times(seval, args):
            """Times in ns of the edges themselves (TS@1 of each edge index)."""
            trace = next(iter(wal.traces.traces.values()))
            scale = timescale_ps(trace) / 1000.0
            return [trace.timestamps[i + 1] * scale for i in edge(seval, args)]
        return op_edge_times

    def op_hex(seval, args):
        """(hex v) or (hex v digits): an int as lower-case hex text, zero-padded to digits."""
        v = seval.eval(args[0])
        digits = seval.eval(args[1]) if len(args) > 1 else 0
        if isinstance(v, (list, tuple)) or type(v).__name__ == 'WList':
            return [f'{x:0{digits}x}' if isinstance(x, int) else str(x) for x in v]
        return f'{v:0{digits}x}' if isinstance(v, int) else str(v)

    return {'changes': op_changes, 'rising-edges': make_edge('0', '1'),
            'falling-edges': make_edge('1', '0'), 'values-at': op_values_at, 'times-ns': op_times_ns,
            'rising-times-ns': make_edge_times('0', '1'), 'falling-times-ns': make_edge_times('1', '0'),
            'hex': op_hex}


# ---------------------------------------------------------------- evaluation

class Runner:
    def __init__(self, wal, args):
        self.wal = wal
        self.args = args
        self.failed = False

    def _indices(self):
        return {tid: t.index for tid, t in self.wal.traces.traces.items()}

    def _restore(self, indices):
        for tid, idx in indices.items():
            if tid in self.wal.traces.traces:
                self.wal.traces.traces[tid].index = idx

    def run_text(self, text, label, filename='', show_result=True):
        """Evaluate every s-expression in text; print output and the last result.
        filename must be a real file or '' (WAL reopens it to show error context)."""
        try:
            sexprs = read_wal_sexprs(text, filename)
        except ParseError as e:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                e.show()
            print(f'> {label}\n! parse error: {buf.getvalue().strip()}')
            self.failed = True
            return
        print(f'> {label}')
        result, buf = None, io.StringIO()
        before = self._indices()
        try:
            with contextlib.redirect_stdout(buf):
                for sexpr in sexprs:
                    result = self.wal.eval(sexpr)
        except (WalEvalError, Exception) as e:  # pylint: disable=broad-except
            self._restore(before)  # a failed expression may leave the cursor moved
            out = re.sub(r'\x1b\[[0-9;]*m', '', buf.getvalue())  # WAL colours its errors
            # WAL prints its own error banner; keep the part after it
            msg = out.split('>>>>> WAL Runtime error! <<<<<')[-1].strip() if 'WAL Runtime error' in out else ''
            printed = out.split('>>>>> WAL Runtime error! <<<<<')[0] if msg else out
            for line in cap_lines(printed, self.args.max_lines):
                print(line)
            detail = msg or f'{type(e).__name__}: {e}'
            print('! error: ' + detail.replace('\n', '\n  '))
            self.failed = True
            return
        for line in cap_lines(buf.getvalue(), self.args.max_lines):
            print(line)
        all_none = isinstance(result, (list, tuple)) and result and all(r is None for r in result)
        if show_result and result is not None and not all_none:
            print('= ' + fmt_value(result, self.args.max_items))


def first_trace(wal):
    return next(iter(wal.traces.traces.values()))


def print_info(wal, waves):
    for tid, trace in wal.traces.traces.items():
        scale = timescale_ps(trace)
        n = len([s for s in trace.rawsignals])
        t0 = trace.timestamps[0] if trace.max_index >= 0 else 0
        t1 = trace.timestamps[trace.max_index] if trace.max_index >= 0 else 0
        print(f'trace {tid}: {trace.filename}')
        print(f'  timescale: {getattr(trace, "timescale", "?")}  (TIMESCALE-PS = {scale})')
        print(f'  time: {t0} .. {t1} TS units = {fmt_time(t0, scale)} .. {fmt_time(t1, scale)}')
        print(f'  indices: 0 .. {trace.max_index}  (one index per timestamp with a value change)')
        print(f'  signals: {n}')
        print(f'  scopes: {" ".join(trace.scopes)}')


def print_signals(wal, pattern, max_items):
    multi = len(wal.traces.traces) > 1
    for tid, trace in wal.traces.traces.items():
        names = [s for s in trace.rawsignals if not pattern or glob_match(s, pattern)]
        names.sort()
        prefix = f'{tid}^' if multi else ''
        for name in names[:max(max_items, 500)]:
            try:
                width = trace.signal_width(name)
            except Exception:  # pylint: disable=broad-except
                width = '?'
            print(f'  {prefix}{name} [{width}]')
        print(f'  ({len(names)} signals{" matching " + repr(pattern) if pattern else ""})')


def print_table(wal, args):
    trace = first_trace(wal)
    if len(wal.traces.traces) > 1:
        print('! --table uses the first waveform only')
    names = [s for s in trace.rawsignals if any(glob_match(s, p) for p in args.table)]
    names = sorted(dict.fromkeys(names))
    if not names:
        print(f'! --table: no signal matches {args.table}')
        return False
    scale = timescale_ps(trace)
    stamps = [trace.timestamps[i] for i in range(trace.max_index + 1)]
    lo = bisect.bisect_left(stamps, parse_time(args.time_from, scale)) if args.time_from else 0
    hi = bisect.bisect_right(stamps, parse_time(args.time_to, scale)) - 1 if args.time_to else trace.max_index
    hi = min(hi, trace.max_index)

    def val(name, idx):
        v = trace.signal_value(name, idx - trace.index)
        if isinstance(v, int):
            width = trace.signal_width(name)
            return str(v) if width == 1 else f'{v:0{(width + 3) // 4}x}'
        return str(v)

    if args.edges:
        clk = [s for s in trace.rawsignals if s == args.edges] or \
              [s for s in trace.rawsignals if glob_match(s, args.edges)]
        if not clk:
            print(f'! --edges: no signal matches {args.edges}')
            return False
        clk = clk[0]
        rows = [i for i in range(max(lo, 0), hi) if val(clk, i) == '0' and val(clk, i + 1) == '1']
        print(f'# rising edges of {clk}; time of the edge, values just before it (hex for vectors)')
    else:
        rows, prev = [], None
        for i in range(max(lo, 0), hi + 1):
            cur = [val(n, i) for n in names]
            if cur != prev:
                rows.append(i)
            prev = cur
        print('# one row per change of any listed signal (hex for vectors)')

    short = [n.split('.')[-1] for n in names]
    if len(set(short)) != len(short):
        short = names
    for k, n in enumerate(names):
        print(f'# c{k} = {n}')
    print('time'.ljust(12) + 'TS'.ljust(12) + ' '.join(f'c{k}:{s}' for k, s in enumerate(short)))
    for i in rows[:args.max_rows]:
        ts = stamps[i + 1] if args.edges else stamps[i]  # an edge happens at the next index
        print(fmt_time(ts, scale).ljust(12) + str(ts).ljust(12) +
              ' '.join(val(n, i).ljust(len(f'c{k}:{s}')) for k, (n, s) in enumerate(zip(names, short))))
    if len(rows) > args.max_rows:
        print(f'... ({len(rows) - args.max_rows} more rows; narrow --from/--to or raise --max-rows)')
    return True


# ---------------------------------------------------------------- main

class OrderedAction(argparse.Action):
    def __call__(self, parser, namespace, values, option_string=None):
        items = getattr(namespace, 'program', None) or []
        items.append((self.dest, values))
        namespace.program = items


def main():
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('waves', nargs='+', help='waveform files (.vcd, .fst, .csv)')
    p.add_argument('-e', dest='expr', action=OrderedAction, help='WAL expression(s)')
    p.add_argument('-f', dest='file', action=OrderedAction, help='WAL file')
    p.add_argument('--info', action='store_true')
    p.add_argument('--signals', nargs='?', const='', default=None, metavar='PATTERN')
    p.add_argument('--table', nargs='+', metavar='PAT')
    p.add_argument('--from', dest='time_from')
    p.add_argument('--to', dest='time_to')
    p.add_argument('--edges', metavar='CLK')
    p.add_argument('--max-rows', type=int, default=100)
    p.add_argument('--setup')
    p.add_argument('--no-setup', action='store_true')
    p.add_argument('--keep', nargs='+', metavar='PAT')
    p.add_argument('--max-items', type=int, default=50)
    p.add_argument('--max-lines', type=int, default=200)
    args = p.parse_args()
    program = getattr(args, 'program', None) or []

    sys.setrecursionlimit(10000)
    wal = Wal()
    for i, wave in enumerate(args.waves):
        if not os.path.isfile(wave):
            print(f'! no such file: {wave}')
            return 2
        keep = None
        if args.keep:
            if not wave.lower().endswith('.vcd'):
                print('! --keep only works on VCD files; loading everything')
            else:
                keep = vcd_names_matching(wave, args.keep)
                if not keep:
                    print(f'! --keep {args.keep} matches no signal in {wave}')
                    return 2
        try:
            with contextlib.redirect_stdout(io.StringIO()) as buf:
                wal.load(wave, f't{i}', keep_signals=keep)
        except Exception as e:  # pylint: disable=broad-except
            print(f'! cannot load {wave}: {type(e).__name__}: {e} {buf.getvalue().strip()}')
            return 2
        if f't{i}' not in wal.traces.traces:
            print(f'! cannot load {wave}: {buf.getvalue().strip()}')
            return 2

    wal.eval_context.global_environment.define('TIMESCALE-PS', timescale_ps(first_trace(wal)))
    runner = Runner(wal, args)

    def op_index_at(seval, op_args):
        """(index-at t): last index whose timestamp is <= t (raw TS units) in the first trace."""
        t = seval.eval(op_args[0])
        trace = first_trace(wal)
        stamps = [trace.timestamps[i] for i in range(trace.max_index + 1)] \
            if not hasattr(op_index_at, 'stamps') else op_index_at.stamps
        op_index_at.stamps = stamps
        return max(bisect.bisect_right(stamps, t) - 1, 0)

    wal.register_operator('index-at', op_index_at)
    for name, func in fast_operators(wal).items():
        wal.register_operator(name, func)
    with contextlib.redirect_stdout(io.StringIO()):
        for sexpr in read_wal_sexprs(PRELUDE):
            wal.eval(sexpr)

    setup = None if args.no_setup else (args.setup or find_setup(args.waves[0]))
    if setup:
        with open(setup, encoding='utf-8-sig') as f:
            runner.run_text(f.read(), f'setup {setup}', setup, show_result=False)

    if args.info:
        print_info(wal, args.waves)
    if args.signals is not None:
        print_signals(wal, args.signals, args.max_items)
    if args.table and not print_table(wal, args):
        runner.failed = True

    for kind, value in program:
        if kind == 'expr':
            runner.run_text(value, value)
        else:
            if value == '-':
                runner.run_text(sys.stdin.read().lstrip('﻿'), '(stdin)')  # PowerShell adds a BOM
            else:
                with open(value, encoding='utf-8-sig') as f:
                    runner.run_text(f.read(), value, value)

    if not (program or args.info or args.signals is not None or args.table):
        print_info(wal, args.waves)
    return 1 if runner.failed else 0


if __name__ == '__main__':
    sys.exit(main())
