# Waveform Analysis with WAL

> **Credits.** WAL (Waveform Analysis Language) is developed by **Lucas Klemmer** and **Daniel Große** at the **Institute for Complex Systems (ICS), Johannes Kepler University Linz** (BSD-3-Clause license).
> Source: [github.com/ics-jku/wal](https://github.com/ics-jku/wal) · Documentation: [wal-lang.org](https://wal-lang.org/documentation/core)
> - L. Klemmer, D. Große, "WAL: A Novel Waveform Analysis Language for Advanced Design Understanding and Debugging", *ASP-DAC*, 2022.
> - L. Klemmer, D. Große, "WAVING Goodbye to Manual Waveform Analysis in HDL Design With WAL", *IEEE TCAD*, vol. 43, no. 10, pp. 3198–3211, 2024. DOI: [10.1109/TCAD.2024.3387312](https://doi.org/10.1109/TCAD.2024.3387312)
>
> This page is an introduction and a set of experiments; the language and its implementation are entirely their work.

Looking at waveforms in GTKWave is how most debugging starts, but it does not scale: counting 300 UART bytes, checking that a signal is stable on every SPI edge, or measuring every gap between two events is slow and error-prone by eye. WAL turns a waveform into something you can **query and program**: a small Lisp-like language whose variables are the signals of a VCD/FST file and which can step through time.

Typical uses:

* **Questions about one run**: when does X first happen, how many times does Y happen, what value does Z have at each event.
* **Checks after simulation**: properties written once and run on every new VCD (a light, post-processing alternative to assertions).
* **Measurements**: periods, latencies, gaps, histograms of FSM states.
* **Feeding a tool or an AI assistant** precise answers instead of megabytes of raw VCD text (see [Using WAL from Claude](#using-wal-from-claude)).

## Installation

```bash
python -m pip install wal-lang      # FST support also needs: python -m pip install pylibfst
```

This installs the Python package and the `wal` / `walc` commands (on Windows they land in the user `Scripts` folder, which may not be on `PATH`; `python -m wal` always works). Tested here with wal-lang 0.9.1 and Icarus Verilog VCDs.

## How WAL sees a waveform

These are the ideas that make WAL code read correctly. They are easy to get wrong, so they come first.

| Concept | Meaning |
|---|---|
| `INDEX` | A trace is the list of **timestamps at which something changed**. `INDEX` walks that list from 0 to `MAX-INDEX`. It is **not** time and **not** clock cycles. |
| `TS` | The timestamp at the current index, in the VCD's timescale units (`$timescale 10ns` → `TS` 1248 = 12 480 ns). |
| Cursor | Every expression is evaluated "at" the current index. `sig@1` reads the next index, `sig@-1` the previous one. |
| `find`, `whenever`, `count` | Loop over every index, evaluate a condition, and restore the cursor afterwards. |
| `(rising s)` | True at the index **just before** the edge: `s` is 0 there and 1 at `@1`. |

The last line has a nice consequence. At a `(rising clk)` index, every signal still has its pre-edge value, which is exactly what flip-flops sample. Whatever the edge produces (a register's new value, and the edge's own time) is read with `@1`:

```lisp
(whenever (rising clk)
  (printf "%d: state %d -> %d\n" TS@1 r3_state r3_state@1))
```

Other details:

* Signals are read as unsigned integers. `(signed sig)` gives two's complement, `sig[3]` a bit, `sig[7:0]` a slice.
* Names are the full hierarchy (`spi_tb.spi_master.r3_state`). The bit range is dropped from the name.
* A scalar `x`/`z` reads as the string `"x"`/`"z"`. Plain WAL 0.9.1 raises a Python error on a vector that contains x/z bits; the helper script below returns those as strings like `"xxxx"`.
* Several changes at the same timestamp are a single index, so delta-cycle glitches are invisible.

## The language in five minutes

```lisp
(define x 5)  (set [x 6])                          ; variables
(defun f [a b] (+ a b))   (fn [x] (* x 2))          ; functions and lambdas
(if c a b)  (cond [c1 ...] [else ...])  (when c ...)
(list 1 2 3) (first l) (length l) l[0] (map f l) (filter p l) (fold f 0 l)
(print "a=" a)  (printf "%d ns  %02x\n" t v)
(alias clk 'tb.clk25)                               ; short names (note the quote)
(defsig busy (= tb.dut.r3_state 2))                 ; virtual signal
(in-scope 'tb.dut ~r3_state)                        ; ~sig = signal of the current scope
(find (rising tb.dv))                               ; -> list of indices
(count (rising tb.dv))                              ; -> number
(whenever (rising tb.dv) (print TS@1 " " tb.data@1))
(reval expr k)  ==  expr@k                          ; evaluate k indices away
```

It can be used from the REPL (`python -m wal`), as a script (`python -m wal -l tb.vcd program.wal`), with `-c` on the command line, or from Python:

```python
from wal.core import Wal
w = Wal()
w.load('modules/spi/test/spi_tb.vcd')
print(w.eval_str('(count (rising spi_tb.w_sck))'))     # 240
```

## Worked examples on this handbook's waveforms

Every output below was produced by running the query; nothing is hand-written. The examples use the helper script `wal_run.py` from the [skill folder](skill/scripts/wal_run.py) (described in the next section), but the WAL code is the same anywhere.

### SPI: every word the slave received

`modules/spi/test/spi_tb.vcd` (timescale 10 ns) comes from the SPI master/slave testbench.

```lisp
(whenever (rising spi_tb.w_received_slave)
  (printf "%.0f ns  %06x\n" (ts->ns TS@1) spi_tb.w24_data_received_slave@1))
```

```
12480 ns  153524
25160 ns  84d609
37840 ns  b97b0d
...        (10 words in total, one every 12 680 ns)
126600 ns  aff7e5
```

### SPI: is MOSI ever changing on a sampling edge?

A small property check; `0` means never violated.

```lisp
(count (&& (rising spi_tb.w_sck) (unstable spi_tb.w_mosi)))      ; = 0
```

### SPI: how many clock cycles does the master FSM spend in each state?

```lisp
(define h (array))
(whenever (rising spi_tb.clk25)
  (seta h spi_tb.spi_master.r3_state
        (+ 1 (geta/default h 0 spi_tb.spi_master.r3_state))))
h      ; = {("x" 1) ("0" 334) ("1" 1440) ("2" 1440)}
```

That is one cycle before reset, 334 idle cycles and 1440 cycles in each of the two transfer states.

### UART: do two receivers on different clocks see the same bytes?

`modules/uart/test/uart_async_tb.vcd` (6.6 MB, timescale 1 ps) has one transmitter and two receivers whose clocks are 2 % fast and 2 % slow.

```lisp
(define f (map (fn [i] (at (+ i 1) uart_async_tb.w8_data_fast)) (find (rising uart_async_tb.w_dv_fast))))
(define s (map (fn [i] (at (+ i 1) uart_async_tb.w8_data_slow)) (find (rising uart_async_tb.w_dv_slow))))
(print (length f) " " (length s) " " (= f s))      ; 300 300 true
```

(`at` evaluates an expression at an absolute index; it is a two-line macro defined by the helper script.)

## Using WAL from Claude

AI coding assistants such as Claude Code are increasingly used to debug RTL, and sooner or later they need to look at a waveform. A VCD is a poor thing to hand a language model: even a small one is thousands of lines of value changes, which costs context and is easy to misread. One answer is a **skill**: a set of instructions the assistant loads when the task calls for it. This one tells Claude to **never read a waveform file directly** and to ask WAL instead, through a helper script that loads the file once, runs the queries and prints compact answers.

To use it, copy the [`skill/`](skill/SKILL.md) folder to `~/.claude/skills/wal/` (user level, available in every project) or to `.claude/skills/wal/` inside one project, and install `wal-lang`. The skill refers to its script by the user-level path; adjust it if you install it per project.

**It runs as a separate, small agent.** The skill's front matter sets `context: fork`, `model: haiku` and `background: false`. When the main session (whatever model it uses) needs something from a waveform, Claude Code starts a fresh Haiku agent with the skill as its instructions. The agent does the querying and returns only the answer, the queries that produced it, and what it did not check. The main conversation never fills up with query output, and the cheapest model does the mechanical work. The benchmark below is what justifies this: with the skill, Haiku answered all ten questions correctly for a few cents. Because the agent does not see the conversation, the skill's description tells the caller to pass everything in the request: waveform path, signal names, encodings, time window and the form of the answer. To run it in the main session instead, remove those three lines from the front matter.

| File | Content |
|---|---|
| [`skill/SKILL.md`](skill/SKILL.md) | When to use it, the workflow, the mental model above, recipes and pitfalls |
| [`skill/reference.md`](skill/reference.md) | Operator reference for wal-lang 0.9.1, checked against the package source |
| [`skill/scripts/wal_run.py`](skill/scripts/wal_run.py) | The helper script |

### The helper script, `wal_run.py`

```bash
python wal_run.py tb.vcd --info                       # timescale, time range, scopes, signal count
python wal_run.py tb.vcd --signals data_received      # find signal names (glob, or substring)
python wal_run.py tb.vcd -e '(count (rising tb.clk))' # any number of -e, one load
python wal_run.py tb.vcd -f checks.wal                # a WAL file; -f - reads stdin
python wal_run.py tb.vcd --table w_sck w_mosi --from 1us --to 2us          # value table
python wal_run.py tb.vcd --table r3_state --edges tb.clk25 --from 1us --to 2us   # one row per clock edge
```

On top of plain WAL it:

* loads the waveform(s) once and runs every expression in order, with each result printed as `= ...` and errors as one `! error:` line instead of a Python traceback; a failed expression no longer leaves the cursor moved;
* returns vectors with x/z bits as strings instead of crashing;
* defines `TIMESCALE-PS`, `(ts->ns t)`, `(at i expr)` (evaluate at an absolute index), and `(index-at t)` / `(at-ns ns expr)` to read a signal at a given time, which plain WAL has no direct way to do;
* loads an optional per-project `wal_setup.wal` (aliases, `defsig`, helper functions) found next to the waveform or in a parent folder;
* adds fast list helpers, `(rising-edges 'sig)`, `(falling-edges 'sig)`, `(changes 'sig)`, `(values-at idxs 'sig)` and `(times-ns idxs 1)`, which scan one signal in a single Python pass and return the same indices as the equivalent `find` (the pulse-width question on the 6.6 MB trace drops from minutes to the ~7 s it takes to load the file);
* prints value tables for "what happens around this time" questions, which are awkward in WAL itself.

On Windows (where it was developed), pass anything non-trivial through stdin (`-f -` with a quoted heredoc). Git Bash rewrites arguments that start with `/` (WAL's division!) into paths, and PowerShell 5.1 drops embedded double quotes.

### Optional project setup: `wal_setup.wal`

A plain WAL file with short names for the signals a project keeps asking about. It is never required.

```lisp
;; wal_setup.wal - for spi_tb.vcd (modules/spi/test; regenerate: python run.py)
(alias clk   'spi_tb.clk25)
(alias rx_dv 'spi_tb.w_received_slave)
(alias rx    'spi_tb.w24_data_received_slave)
(defsig sck_rise (rising spi_tb.w_sck))
```

## Claude with and without WAL: a measured comparison

Does the skill actually help? The folder [`test/`](test/run_bench.py) holds a small, repeatable benchmark that answers this for any model:

| File | Content |
|---|---|
| [`test/questions.json`](test/questions.json) | 10 questions on three waveforms of this repository, each with the JSON shape of its answer |
| [`test/golden.json`](test/golden.json) | the correct answers and the grading tolerances; each was computed twice (WAL and an independent Python VCD parser) and both agreed |
| [`test/run_bench.py`](test/run_bench.py) | runs every question through `claude -p`, per model and per method, grades the answers and writes a report |
| `test/results/<run>/` | `report.md` and `results.json` of each run (full transcripts in `raw/`, not committed) |

The questions, five easy and five difficult:

| | Waveform | Question |
|---|---|---|
| E1 | SPI (`spi_tb.vcd`, 130 kB) | time and received value of each of the 10 SPI words |
| E2 | SPI | SCK period during a word |
| E3 | UART (`uart_async_tb.vcd`, 6.6 MB) | bytes delivered by each receiver, are the sequences identical, first 5 bytes |
| E4 | UART | time of reset release and of the first TX falling edge |
| E5 | UART | shortest and longest low pulse on TX |
| D1 | SPI | per FSM state: number of visits and average/min/max visit length in clock cycles |
| D2 | scope (`scope_tb.vcd`, 2 MB) | per capture: clock cycles from arm to capturing and from capturing to done |
| D3 | scope | trigger pulses that arrive while armed (two conditions on the same edge), and how many are ignored (state at the next edge) |
| D4 | UART | per-byte delay between the two receivers: average, min, max, which one is first |
| D5 | UART | decode the serial line as 8N1 frames and check it against the receiver: frames, mismatches, bad stop bits, min/max frame spacing |

**How a run works.** Every question is a separate, non-interactive Claude Code session (`claude -p`) started in an empty scratch folder with `--safe-mode`, so no installed skills, `CLAUDE.md`, memory or plugins take part. The two methods differ only in what the session is told:

* **with WAL**: the text of [`skill/SKILL.md`](skill/SKILL.md) is added to the system prompt, and the session must use `skill/scripts/wal_run.py` for every look at the waveform;
* **without**: anything except WAL (in practice the model writes its own VCD parser).

The answer is forced into JSON with `--json-schema` and graded automatically. Time, cost and number of turns come from Claude Code's own JSON result, so the cost is what the session actually cost, not an estimate.

```bash
cd verification/waveforms-analysis/test
python run_bench.py --dry-run                                  # what would run, worst-case cost
python run_bench.py --models haiku,sonnet,opus --update-md     # full run, writes the table below
python run_bench.py --models sonnet --questions D1,D5 --arms wal   # a subset
python run_bench.py --regrade results/<run>                    # re-grade after editing golden.json
```

A full run is 10 questions × 2 methods × each model, one session each; `--max-budget-usd` caps every session (default $2) and `--jobs` sets how many run in parallel.

**Improving the skill with it.** Every answer includes a `notes` field where the model writes what was awkward or ambiguous, and `report.md` lists those notes together with every failed check. The loop is: run, read the notes and failures of the WAL sessions, fix the skill, re-run. Several entries in the skill's pitfall list came from exactly this (see the exploratory runs below).

### Results

<!-- BENCH:START -->
Run 20261104-192959: Claude Code 2.1.318, effort default, 10 questions, one fresh session per question. Rows haiku without, opus without, sonnet without are reused from run 20261104-191157.

| Model | Method | Easy | Difficult | Total | Time (s) | Cost | Avg turns |
|---|---|---|---|---|---|---|---|
| haiku | with WAL skill | 5/5 | 5/5 | **10/10** | 493 | $0.07 | 5.5 |
| haiku | without | 4/5 | 5/5 | **9/10** | 262 | $0.07 | 6.0 |
| opus | with WAL skill | 5/5 | 5/5 | **10/10** | 226 | $1.15 | 3.2 |
| opus | without | 5/5 | 4/5 | **9/10** | 203 | $1.71 | 4.1 |
| sonnet | with WAL skill | 5/5 | 5/5 | **10/10** | 305 | $0.58 | 3.6 |
| sonnet | without | 5/5 | 4/5 | **9/10** | 231 | $0.87 | 4.7 |

Per question (✓/✗, wall-clock seconds, cost):

| Question | haiku WAL | haiku no WAL | opus WAL | opus no WAL | sonnet WAL | sonnet no WAL |
|---|---|---|---|---|---|---|
| E1 (easy) | ✓ 12 s $0.01 | ✓ 29 s $0.01 | ✓ 10 s $0.10 | ✓ 29 s $0.17 | ✓ 11 s $0.05 | ✓ 23 s $0.09 |
| E2 (easy) | ✓ 23 s $0.01 | ✗ 18 s $0.00 | ✓ 10 s $0.10 | ✓ 11 s $0.16 | ✓ 12 s $0.05 | ✓ 8 s $0.07 |
| E3 (easy) | ✓ 60 s $0.01 | ✓ 21 s $0.01 | ✓ 16 s $0.12 | ✓ 18 s $0.16 | ✓ 16 s $0.05 | ✓ 28 s $0.08 |
| E4 (easy) | ✓ 29 s $0.00 | ✓ 26 s $0.01 | ✓ 17 s $0.10 | ✓ 15 s $0.15 | ✓ 16 s $0.05 | ✓ 21 s $0.07 |
| E5 (easy) | ✓ 60 s $0.01 | ✓ 19 s $0.01 | ✓ 38 s $0.12 | ✓ 21 s $0.18 | ✓ 42 s $0.07 | ✓ 30 s $0.09 |
| D1 (difficult) | ✓ 49 s $0.01 | ✓ 31 s $0.01 | ✓ 14 s $0.11 | ✗ 24 s $0.19 | ✓ 13 s $0.05 | ✗ 15 s $0.08 |
| D2 (difficult) | ✓ 61 s $0.01 | ✓ 28 s $0.01 | ✓ 31 s $0.12 | ✓ 16 s $0.16 | ✓ 53 s $0.06 | ✓ 35 s $0.11 |
| D3 (difficult) | ✓ 101 s $0.01 | ✓ 30 s $0.01 | ✓ 20 s $0.11 | ✓ 25 s $0.18 | ✓ 71 s $0.06 | ✓ 24 s $0.09 |
| D4 (difficult) | ✓ 23 s $0.00 | ✓ 25 s $0.01 | ✓ 18 s $0.11 | ✓ 17 s $0.17 | ✓ 23 s $0.05 | ✓ 13 s $0.08 |
| D5 (difficult) | ✓ 76 s $0.01 | ✓ 36 s $0.01 | ✓ 52 s $0.16 | ✓ 25 s $0.20 | ✓ 50 s $0.09 | ✓ 33 s $0.10 |
<!-- BENCH:END -->

**Reading the results.** The no-WAL rows come from the first run (20261104-150116). The WAL rows are the latest of three WAL runs, each made after improving the skill from the previous run's notes and failures:

| WAL run | Skill changes before it | Correct | Total time | Cost |
|---|---|---|---|---|
| 20261104-150116 | (first version) | 29/30 | 2384 s | $3.40 |
| 20261104-191157 | fast edge helpers; `define` and format pitfalls | 29/30 | 969 s | $3.32 |
| 20261104-192959 | `hex`, `rising-times-ns`, "never convert numbers by hand" | **30/30** | 1024 s | $1.81 |
| *without WAL* | | *27/30* | *696 s* | *$2.64* |

Every failure was checked by hand against the waveform, and all are genuine:

* **Without WAL, every failure was a parsing slip in the model's own script.** Haiku ignored the 10 ns timescale (E2: 48 ns instead of 480). Sonnet and Opus both miscounted the FSM visits in D1 because they got the order of changes within one timestamp wrong: a state change that happens *at* the clock edge was sampled as if it had happened before it. These are exactly the conventions WAL fixes once (`TS@1`, `sig@1`, `ts->ns`), and a hand-written parser has to get right again every time.
* **With WAL, the failures came after the query, not from it**, and the skill was changed to prevent each one. In the first run, Haiku measured all four D4 numbers correctly and then counted "slow receiver first" backwards. In the second, Sonnet read the right E1 values and converted one from decimal to hex in its head (`b91b0d` instead of `b97b0d`); the skill now offers `(hex v 6)` and says never to convert numbers by hand. In the third run, all three models answered all ten questions correctly.
* **Time.** WAL's interpreter evaluates every condition at every timestamp, which made the first WAL run 3.4× slower than the hand-written parsers. The fast edge helpers cut that to about 1.5×. Per model, the latest run took 493 s with Haiku, 305 s with Sonnet and 226 s with Opus, against 262 s, 231 s and 203 s without WAL.
* **Cost.** Do not read much into the cost differences between runs. Turns and output tokens stayed about the same; the cost of the third run fell mainly because consecutive sessions reused Claude's prompt cache (the shared system prompt was cached instead of re-sent), which depends on timing, not on the skill. Within a run, a session with the skill costs a little more, because the skill text is part of its prompt. The cheapest correct setup was Haiku with the skill: 10/10 for $0.07 for all ten questions.

**What the third run's notes added.** Two models reported a counter that "silently did not update". It turns out that in WAL a `set` inside a closure nested in another closure (`map` inside `map`) is lost without an error; one level deep works. This is now in the skill's pitfall list. It has not been benchmarked yet.

### Exploratory runs

Before the benchmark existed, the same kind of comparison was run twice by hand with two Claude Opus 5.5 agents started side by side (one agent per method answering all questions in one session, so these numbers are not directly comparable with the table above):

| | Questions | With WAL | Without WAL |
|---|---|---|---|
| Run 1 | 6 (the easy ones plus an FSM histogram) | 6/6, 167 s, 52.0 k tokens | 6/6, 61 s, 45.9 k tokens |
| Run 2 | the 10 above | 10/10, 325 s, 59.7 k tokens | 10/10, 77 s, 49.2 k tokens |

What they showed:

* **Both methods got everything right** in these two runs (one Opus agent per method), so they suggested the skill does not improve correctness. The full benchmark above, with one session per question and three models, shows that a hand-written parser does slip now and then.
* **WAL was 3–4× slower.** Most of the time is WAL itself: its interpreter evaluates every condition at every index, so one pass over the 6.6 MB UART file takes 10–30 s, and a hand-written single-pass parser reads it in a few seconds. Tokens (and so cost) were 10–20 % higher with the skill, because the skill text itself is read.
* **Both methods hide traps.** The WAL agent decoded one UART frame wrongly until it noticed that `sig@1` past the last index is `#f`, which WAL considers equal to 0. The independent parser written to check the golden answers crashed on the scope waveform: VCD signal identifiers may start with `#` (`#%`), which it took for a timestamp. Neither error would be obvious from the final number alone. The skill now documents the WAL one and adds `(index-at t)` / `(at-ns ns expr)` for the time lookups the agent was missing.

Where WAL should pay off, and what the benchmark does not measure yet: open-ended debugging questions ("why does the testbench fail around 40 us?") rather than fully specified ones; repeated work on the same project, where a `wal_setup.wal` and saved `.wal` checks are reused instead of a new parser being written every time; and answers that a human can re-run and read as a short query instead of reviewing a throw-away script.

## Limits and pitfalls (wal-lang 0.9.1)

* **Speed.** WAL interprets the condition at every index. On the 6.6 MB UART VCD (320 k indices) loading takes ~7 s and each full pass (`find`, `count`, `whenever`) ~10 s; answering the UART questions of the comparison above took between 48 and 68 s per batch, where a purpose-written Python script needs about a second. WAL wins on writing time, not on run time. For single-signal questions (edges, pulse widths, values at events) the helper script's fast list helpers avoid the per-index interpreter.
* `(sort l)` from the standard library crashes; `(fold/signal + ...)` needs a `fn`, not a bare `+`.
* `alias` and `in-scope` evaluate their argument: write `(alias a 'tb.sig)`, `(in-scope 'tb.dut ...)`.
* `sig@1[7:0]` slices the `1`, not the signal; write `(slice sig@1 7 0)`.
* Dictionary (`array`) keys become strings.
* A `set` inside a closure nested in another closure (`map` inside `map`) does not update an outer variable, and raises no error. Count with `filter`/`length` or `fold` instead.
* `define` fails on a name that already exists; update with `set`.
* FST files need `pylibfst`. Icarus writes VCD by default, which needs nothing extra.
