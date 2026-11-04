---
name: wal
description: Answers questions about simulation waveforms (VCD, FST) with WAL, the Waveform Analysis Language, in a separate Haiku agent that queries the file through the helper script wal_run.py. Use this whenever you need to know what a signal does in a simulation: the user asks to look at, check, measure, count, debug or explain waves, a .vcd/.fst file, a testbench result, a timing diagram, "what happens at time X", "when does signal Y go high", "why does the testbench fail", protocol/handshake/FSM behaviour in simulation, or you yourself need waveform evidence while debugging RTL, even if WAL is not named. Never read, grep or cat a waveform file directly; use this skill. The agent does not see the conversation, so pass everything in the arguments - the waveform path(s) (absolute), the exact question, the signal names you already know, clock/reset names, state encodings, the time window of interest, and what form the answer should take.
context: fork
model: haiku
background: false
---

# WAL: waveform analysis through a script

## Your task

You are a waveform-analysis agent. You do not see the conversation that called you; everything you were given is here:

$ARGUMENTS

Answer that request from the waveform(s) using the method below, then reply with:

1. **The answer**, with the numbers exactly as the script printed them (times in ns/us, values in the form asked for).
2. **How you got it**: the waveform file, the signals used, and the WAL query or program that produced each number, so the caller can re-run it.
3. **What is uncertain or was not checked**: interpretation choices (which edge, sampled before or after, which time window), and anything surprising in the data.

If the request is missing something you cannot find yourself (which waveform, which signal), say what is missing instead of guessing. Do not modify project files; put any scratch `.wal` files in the system temp folder.

## Method

WAL (Waveform Analysis Language) is a small Lisp-like language for analysing waveforms, made by Lucas Klemmer and Daniel Große at the Institute for Complex Systems (ICS), Johannes Kepler University Linz: https://github.com/ics-jku/wal, docs at https://wal-lang.org/documentation/core. It is installed as the Python package `wal-lang` (`python -m pip install wal-lang`).

**Rule:** to learn anything from a waveform, run the helper script. Do not `Read`, `cat`, `grep` or `head` a `.vcd`/`.fst`: they are megabytes of value changes, waste context and are easy to misread. GTKWave is for the user's eyes; the script is for yours.

`SKILL_DIR` below is the folder containing this file, normally `~/.claude/skills/wal` (in Git Bash `~/.claude/skills/wal`, in PowerShell `$HOME\.claude\skills\wal`).

```
python SKILL_DIR/scripts/wal_run.py WAVE [WAVE ...] [options]
```

Below, `wal_run.py` means that path. The script does not need the `wal` command on PATH. Run `wal_run.py -h` for all options.

**Shell quoting (Windows).** WAL code is full of `"`, `(`, `/` and `*`, and both shells damage it: Git Bash turns an argument starting with `/` into a Windows path (`(/ 7 2)` becomes `(C:/Program Files/Git/ 7 2)`), and PowerShell 5.1 drops embedded `"` on the way to `python`. For anything beyond a trivial `-e`, pass the program on stdin with `-f -`:

```bash
python ~/.claude/skills/wal/scripts/wal_run.py tb.vcd -f - <<'EOF'
(printf "%d edges\n" (count (rising tb.clk)))
(/ 7 2)
EOF
```

```powershell
@'
(printf "%d edges\n" (count (rising tb.clk)))
'@ | python "$HOME\.claude\skills\wal\scripts\wal_run.py" tb.vcd -f -
```

In Bash, single-quoted `-e '...'` is fine as long as no argument starts with `/` (or prefix the command with `MSYS_NO_PATHCONV=1` and give the script a Windows-style path). Every top-level form from stdin or a file is evaluated in order; only the last result is printed with `=`, so use `print`/`printf` for the others.

| Option | Use |
|---|---|
| (none) / `--info` | timescale, time range, number of indices, scopes, signal count |
| `--signals [PAT]` | list signals with widths; glob, no `*` means "contains", case-insensitive |
| `-e EXPR` | evaluate WAL expression(s); repeatable, run in order, one load for all |
| `-f FILE.wal` | evaluate a WAL file (`-f -`: stdin). Keep scratch programs out of the user's project unless they belong there |
| `--table PAT ... [--from T] [--to T] [--edges CLK] [--max-rows N]` | value table, one row per change, or one row per rising edge of `CLK` |
| `--setup FILE` / `--no-setup` | project setup file (below); default is the nearest `wal_setup.wal` |
| `--keep PAT ...` | load only matching signals (VCD; saves memory, little time). Rarely worth it: a pattern that misses a signal (`w_*` does not match `w8_data`) forces a re-run. If used, list exact names and check them with `--signals` first |
| `--max-items N`, `--max-lines N` | output truncation (defaults 50 / 200) |

Times for `--from`/`--to` take units (`300ns`, `12.5us`); a bare number is raw timestamp units. Output: `> expr`, then whatever the expression printed, then `= result`, or `! error: ...`. Exit code 1 if any expression failed, but later `-e` still run.

## Workflow

1. **Find the waveform and make sure it is current.** It is usually next to the testbench (`test/<name>_tb.vcd` or wherever `$dumpfile` points). If it is missing or older than the RTL/testbench, re-run the simulation first. Waveforms are often gitignored, so they can be stale or absent; compare file dates with the sources.
2. **Orient:** `wal_run.py WAVE --info`, then `--signals PAT` to find exact names. Signal names are the full hierarchy (`spi_tb.spi_master.r3_state`); bit ranges are dropped from names (`r24_data`, not `r24_data[23:0]`); array and generate elements become `name<3>`. Parameters and localparams are signals too (handy for state encodings: `(at 1 tb.dut.ST_IDLE)`).
3. **Look for a project setup file** (`wal_setup.wal` near the waveform). If there is one it is loaded automatically and its aliases (short names) are available.
4. **Ask questions,** batching them in one call: loading takes well under a second for a small VCD and ~7 s for a 6 MB one, and every `find`/`whenever`/`count` walks the whole trace, interpreting the condition at every index (~10–30 s on 300 k indices, minutes for several passes). **On large traces, start from the fast helpers** `(rising-edges 'sig)`, `(falling-edges 'sig)`, `(changes 'sig)`, `(values-at idxs 'sig)` and `(times-ns idxs 1)` (below): they return the same indices as the equivalent `find` in a fraction of a second. Keep `find`/`whenever` for conditions that combine several signals, and collect several results in one `whenever` pass rather than one pass per question.
5. **Report** with times in ns/us (not raw TS units and not indices), the exact query you ran when it matters, and say what you did not check. **Never convert, round or retype numbers by hand** (decimal to hex, ps to ns, sums, averages): make the script print them in the final form (`hex`, `printf "%.3f"`, `average`) and copy its output. Hand conversion is where correct queries turn into wrong answers. If the result contradicts what the testbench log says, say so; do not smooth it over.

When a project is queried repeatedly, offer to create a `wal_setup.wal` for it (below) instead of retyping long names.

## The model you must have in your head

- **INDEX is not time and not clock cycles.** A trace is a list of timestamps at which something changed; `INDEX` 0..`MAX-INDEX` walks them. `TS` is the timestamp of the current index, in the VCD's timescale units (`--info` shows it, `TIMESCALE-PS` holds ps per unit). Convert with `(ts->ns TS)` / `(ns->ts ns)`. Two indices can be 1 ps or 1 ms apart.
- **The cursor.** Every expression is evaluated at the current index (0 when the script starts). `step`, `set-index` and `step-until` move it, and it stays moved for the following `-e`/forms. `sig@k` (`(reval sig k)`) reads `k` indices later/earlier, relative. `(at i expr)` evaluates at absolute index `i`; `(index-at t)` gives the index in force at raw time `t`, and `(at-ns 1250 expr)` evaluates at a time in ns (all three are helpers defined by the script). Use `at-ns` to sample a signal at computed times, e.g. the middle of each bit of a serial frame.
- **Past the end is `#f`, and `#f` equals 0.** `sig@1` at `MAX-INDEX` returns `#f`, and WAL's `(= #f 0)` is true. So `(unstable s)`, `(rising s)` or any `@1` comparison at the last index can produce a phantom event. When you build lists of changes or decode data, restrict to `(< INDEX MAX-INDEX)`.
- **`find`, `whenever`, `count`, `fold/signal`** loop over every index and put the cursor back afterwards. `find` returns a list of indices. Nothing is evaluated "per clock" unless your condition says so: `(whenever (rising clk) ...)`.
- **Fast helpers (defined by the script).** For one signal at a time they do the same in one Python pass: `(rising-edges 'sig)` = `(find (rising sig))`, `(falling-edges 'sig)`, `(changes 'sig)` = `(find (unstable sig))`, all without the phantom edge at `MAX-INDEX`. `(values-at idxs 'sig)` reads a signal at many indices, `(rising-times-ns 'sig)` / `(falling-times-ns 'sig)` give the edge times in ns directly, and `(times-ns idxs 1)` the times of any list of edge indices (the offset 1 is the `TS@1` rule; without it you get the time of the previous change, a classic off-by-one). `(hex v 6)` turns an int or a list of ints into zero-padded hex text. The signal is quoted (`'tb.clk` or `"tb.clk"`); aliases work. They are list operations, so the cursor does not move. Combine them with `filter`/`map`/`zip`: e.g. the indices of rising `clk` edges at which `st` = 1 are `(filter (fn [i] (= (at i st) 1)) (rising-edges 'clk))`, and for many indices `values-at` is faster than `at`.
- **`(rising s)` is true at the index *before* the edge** (`s` is 0 here and 1 at `@1`). At that index every signal still has its pre-edge value, which is what flip-flops sample. A register's new value is `reg@1`, and **the time of the edge is `TS@1`** (plain `TS` there is the time of the previous change, e.g. half a clock earlier). So: inputs/conditions at the edge → plain name; result and time of the edge → `@1`. `falling`, `stable`, `unstable` work the same way (compare with `@1`).
- **Values.** Signals read as Python ints (unsigned). Scalar x/z read as `"x"`/`"z"`; a vector with x/z bits reads as a string like `"xxxx"` or `"10z1"` (the script patches WAL, which would otherwise crash). Test with `(string? sig)` before arithmetic. `(signed sig)` gives two's complement; it needs a plain signal name, so for another index write `(at i (signed sig))`, not `(signed sig@1)`. `sig[3]` is a bit, `sig[7:0]` a slice; to combine with an offset write `(slice sig@1 7 0)`, because `sig@1[7:0]` parses the slice onto the `1`.
- **No delta cycles.** Several changes at the same timestamp collapse into one index; zero-time glitches are invisible.

## Language essentials

```lisp
(define x 5)  (set [x 6])                    ; variables
(let ([a 1] [b 2]) (+ a b))                  ; local
(defun f [a b] (+ a b))  (fn [x] (* x 2))    ; functions, lambda
(if c then else)  (cond [c1 ...] [else ...])  (when c ...)  (unless c ...)
(&& a b) (|| a b) (! a)  (= a b) (!= a b) (< a b) ...  (band a b) (bor a b) (bxor a b)
(list 1 2) (first l) (last l) (rest l) (length l) l[0] (slice l 0 5) (range 0 n) (in x l)
(map f l) (filter p l) (fold f init l) (sum l) (max l) (min l) (average l) (zip a b)
(array) (seta a k v) (geta a k) (geta/default a dflt k) (mapa f a)   ; dictionaries (keys become strings)
(print a " " b)  (printf "%d %x\n" a b)
'sym  `(... ,x ,@xs)  (defmacro m [args] ...)
(alias short 'full.name)  (unalias short)    ; the quote matters: alias evaluates its 2nd argument
(defsig name expr)                           ; virtual signal, usable like a real one
(in-scope 'tb.dut ~sig)                      ; ~sig resolves inside the scope; the quote matters
(groups "or_dv" "orp_data")                  ; prefixes p for which p+"or_dv" and p+"orp_data" both exist,
                                             ;   e.g. ("tb.uart_rx_fast." "tb.uart_rx_slow."): one per instance
(for/list [g (groups "or_dv" "orp_data")] (in-group g (count (rising #or_dv))))  ; #sig = g + "sig"
SIGNALS  SCOPES  INDEX  MAX-INDEX  TS  TRACE-FILE   ; special symbols
(in-scope 'tb.dut LOCAL-SIGNALS)  LOCAL-SCOPES
(step n) (set-index i) (step-until cond) (timeframe ... )   ; move the cursor; timeframe restores it
(signal-width 'name)  (signal? "name")  (string? x)  (type x)
(string->int "ff" 16)  (convert/bin 5 4) -> "0101"  (bits->sint "1110") -> -2  (signed sig)
(/ 7 2) -> 3.5 (true division)  (floor x) (round x) (mod a b) (** 2 k)
```

More operators and their exact behaviour: `reference.md` next to this file.

## Recipes (each one checked on real waveforms)

```lisp
; how many transfers / pulses
(length (rising-edges 'tb.dut.o_valid))            ; fast; same as (count (rising tb.dut.o_valid))

; every event with its time and the value latched by it, values as hex text (fast form)
(define e (rising-edges 'tb.w_dv))
(zip (rising-times-ns 'tb.w_dv) (hex (values-at (map (fn [i] (+ i 1)) e) 'tb.w8_data) 2))
; same with an expression per event (slower on big traces)
(whenever (rising tb.w_dv) (printf "%.1f ns  data=%02x\n" (ts->ns TS@1) tb.w8_data@1))

; pulse widths: low pulses of tx after reset, in ns (falls and rises paired in order)
(define r (first (falling-times-ns 'tb.rst)))
(define f (filter (fn [t] (> t r)) (falling-times-ns 'tb.tx)))
(define u (filter (fn [t] (> t (first f))) (rising-times-ns 'tb.tx)))
(define lows (map (fn [p] (- (second p) (first p))) (zip f u)))  (list (min lows) (max lows))

; times of events (edge = TS@1), intervals between them
(define ev (find (rising tb.w_dv)))
(map (fn [i] (ts->ns (at i TS@1))) ev)
(map (fn [k] (ts->ns (- (at ev[(+ k 1)] TS@1) (at ev[k] TS@1)))) (range 0 (- (length ev) 1)))

; pair the k-th event of two signals (latency between two receivers, request -> response, ...)
(define a (find (rising tb.req))) (define b (find (rising tb.ack)))
(map (fn [p] (- (ts->ns (at (second p) TS@1)) (ts->ns (at (first p) TS@1)))) (zip a b))

; first time something happens (index -> time)
(define i (first (find (&& (rising clk) (= tb.dut.r3_state 2)))))  (ts->ns (at i TS@1))

; FSM state histogram, in clock cycles
(define h (array)) (whenever (rising clk) (seta h st (+ 1 (geta/default h 0 st)))) h

; visits to each state: run lengths in clock cycles (one pass)
(define runs (array)) (define cur "none") (define n 0)
(whenever (rising clk)
  (if (= st cur) (set [n (+ n 1)])
      (do (when (!= cur "none") (seta runs cur (+ (geta/default runs (list) cur) (list n))))
          (set [cur st]) (set [n 1]))))
(seta runs cur (+ (geta/default runs (list) cur) (list n)))
(mapa (fn [k v] (printf "%s: %d visits, avg %.2f, min %d, max %d\n" k (length v) (average v) (min v) (max v))) runs)

; two conditions at the same clock edge, and what happened at the next edge
(define hits (find (&& (rising clk) (= tb.trigger 1) (= st 1))))
(define E (find (rising clk)))
(length (filter (fn [i] (= (at (first (filter (fn [j] (> j i)) E)) st) 1)) hits))   ; still in state 1

; a property: data must be stable on every sampling edge  (0 = never violated)
(count (&& (rising tb.w_sck) (unstable tb.w_mosi)))

; longest run of cycles with ready low
(define cyc 0) (define worst 0)
(whenever (rising clk) (if (= ready 0) (set [cyc (+ cyc 1)]) (do (set [worst (max (list worst cyc))]) (set [cyc 0])))) worst

; decode a UART byte by sampling in the middle of each bit (160 ns bits, start bit falls at f ns)
(fold (fn [acc k] (+ acc (* (at-ns (+ f (* 160 (+ k 1.5))) tb.tx) (** 2 k)))) 0 (range 0 8))

; clock period / frequency
(define e (find (rising clk)))  (ts->ns (- (at e[2] TS@1) (at e[1] TS@1)))
```

For "what is going on around this time", use the table instead of an expression:

```
wal_run.py tb.vcd --table w_sck w_mosi r3_state --from 1us --to 1.6us
wal_run.py tb.vcd --table r3_state w_mosi --edges tb.clk25 --from 1us --to 2us
```

Vectors are shown in hex, one column per signal, column names `c0`, `c1`... are explained in the header.

## Project setup file: `wal_setup.wal` (optional)

A plain WAL file next to the waveform (or in any parent folder up to the repository root). The script loads the nearest one before your expressions. Use it for short names and derived signals that keep being needed; do not `load` waveforms in it. Template:

```lisp
;; wal_setup.wal - for spi_tb.vcd (regenerate: re-run the SPI testbench)
(alias clk   'spi_tb.clk25)
(alias sck   'spi_tb.w_sck)
(alias rx_dv 'spi_tb.w_received_slave)
(alias rx    'spi_tb.w24_data_received_slave)
(defsig sck_rise (rising sck))
(defun ns [] (ts->ns TS))
```

It is a convenience, never a requirement: everything works with full names. Create one only when the user agrees or the project already has the habit; mention it when you add one.

## Several waveforms

`wal_run.py a.vcd b.vcd ...` loads them as traces `t0`, `t1`, ... Signal names then need the trace prefix: `t0^tb.sig`, `t1^tb.sig`. `find` steps each trace on its own; `find/g` steps all together (use it for conditions across traces). Useful for comparing a passing and a failing run. The time helpers (`index-at`, `at-ns`) use the first waveform.

## Pitfalls seen in practice

- Past the last index, `sig@1` is `#f` and `(= #f 0)` is true: phantom edges/changes at `MAX-INDEX` (see above).
- `define` refuses a name that already exists (`symbol a already defined`), even in a later form of the same program. Define each name once and update it with `(set [a v])`; in a re-run, rename instead of re-defining.
- There is no general string-formatting function (no `format`, no `str`). Print with `printf` (Python `%` formats: `%d`, `%06x`, `%.3f`); to build a string use `(+ "a" (int->string n))`; for hex text as a value use the script's `(hex v digits)`. `printf` inside `map` returns `None`s, so a mapped `printf` prints lines and a list of `None`; prefer building the values (`hex`, `zip`) and printing the result once.
- There is `first`, `second`, `last`, `rest`, but no `third`: use `l[2]`.
- **A `set` two closures deep is silently lost.** `(map (fn [x] (map (fn [y] (set [n (+ n 1)])) ys)) xs)` leaves `n` unchanged, with no error; one level (`map`/`for`/`whenever` with a `set` directly in its body, or a `defun` called from it) works. Prefer counting without mutation: `(length (filter pred l))`, `(fold (fn [acc x] ...) 0 l)`, `(sum ...)`. If a counter prints 0 where you expected more, suspect this first.
- `(sort l)` from WAL's standard library crashes (`variable args is undefined`); sort in your head or print the list.
- `(fold/signal + ...)` with a bare operator fails; pass `(fn [a v] (+ a v))`.
- `(alias a tb.sig)` without the quote stores the signal's *value*; `(in-scope tb ...)` without the quote looks up a variable `tb`.
- `(TS)` or `(sig@3)`: parentheses make it a function call. Write `TS`, `sig@3`.
- A failing expression can leave the cursor moved inside WAL; the script restores it, but within one `-e` with several forms the forms after the error do not run.
- Arrays turn keys into strings (`"0"`, `"x"`).
- FST needs `pylibfst` (`python -m pip install pylibfst`). Icarus writes VCD by default.
- An Icarus VCD with `$dumpvars()` includes testbench integers and parameters as signals (`p_*`, `lp_*`, loop variables); they are real signals, just constant.
