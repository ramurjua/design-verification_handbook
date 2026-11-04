# WAL operator reference (wal-lang 0.9.1, as installed)

Checked against the installed package source (`site-packages/wal/ast_defs.py`, `implementation/*.py`, `libs/std/std.wal`) and by running each form on real Icarus Verilog waveforms. Official docs: https://wal-lang.org/documentation/core. If the package is upgraded, re-check the entries marked (!).

## Syntax

| Form | Meaning |
|---|---|
| `; text` | comment |
| `123` `0xff` `0b101` `1.5` `"str"` `#t` `#f` (`true` `false`) | literals |
| `(op a b)`, `[ ... ]`, `{ ... }` | lists; `[]` and `{}` are just alternative brackets |
| `'x`, `` `(a ,b ,@c) `` | quote, quasiquote / unquote / splice |
| `sig@k` | `(reval sig k)`: value `k` indices from the cursor; `#f` past either end, and `(= #f 0)` is true (!) |
| `x[i]`, `x[hi:lo]` | `(slice x i)` / `(slice x hi lo)`: bit or bit range of an int; element or sub-list of a list (`(slice l a b)` = `l[a:b]` in Python) |
| `~sig` | signal in the current scope (`in-scope`) |
| `#sig` | signal in the current group (`in-group`) |
| `t1^tb.sig` | signal of trace `t1` when several are loaded |

Precedence trap (!): `sig@1[7:0]` is `sig@(1[7:0])`. Write `(slice sig@1 7 0)`; `sig[7:0]@1` also parses as the slice of the shifted value.

## Waveform access

| Form | Notes |
|---|---|
| `INDEX`, `MAX-INDEX`, `TS` | cursor, last index, timestamp at cursor (timescale units) |
| `SIGNALS`, `SCOPES`, `TRACE-NAME`, `TRACE-FILE` | lists / strings; with several traces names carry `tid^` |
| `LOCAL-SIGNALS`, `LOCAL-SCOPES` | relative to the current scope: `(in-scope 'tb.dut LOCAL-SIGNALS)` |
| `VIRTUAL-SIGNALS` | names created with `defsig` |
| `(step)` `(step n)` `(step n 't1)` | move cursor(s); returns trace ids that ran out of range |
| `(set-index i)`, `(set-index/all i)` | absolute move; `#f` if out of range |
| `(step-until c)`, `(step-while c)` | move until/while condition; returns the new INDEX |
| `(timeframe body...)` | run body, then restore every cursor |
| `(reval expr k)` | evaluate at a relative offset, cursor restored |
| `(at i expr)` | absolute index (defined by `wal_run.py`, not WAL itself) |
| `(index-at t)`, `(at-ns ns expr)`, `(ts->ns t)`, `(ns->ts ns)`, `TIMESCALE-PS` | time lookup and conversion (defined by `wal_run.py`, first trace) |
| `(rising-edges 'sig)` `(falling-edges 'sig)` `(changes 'sig)` | fast index lists, same as `find` with `rising`/`falling`/`unstable` minus the phantom at `MAX-INDEX` (defined by `wal_run.py`) |
| `(values-at idxs 'sig)`, `(times-ns idxs [offset])` | fast value / time lookup for a list of indices; offset 1 = edge times (defined by `wal_run.py`) |
| `(rising-times-ns 'sig)`, `(falling-times-ns 'sig)` | edge times in ns directly (defined by `wal_run.py`) |
| `(hex v [digits])` | int or list of ints -> lower-case hex text, zero-padded (defined by `wal_run.py`) |
| `(find c)` | list of indices where `c` holds; each trace stepped separately; cursor restored |
| `(find/g c)` | same, all traces stepped together; with several traces each element is a `{tid index}` array |
| `(whenever c body...)` | run body at every index where `c` holds; cursor restored; returns the last body value |
| `(count c)` | `(length (find c))` |
| `(fold/signal f acc stop sig)` | fold `sig`'s values from the cursor until `stop`; `f` must be a `fn` (!) |
| `(rising s)` `(falling s)` | true at the index *before* the edge |
| `(stable s)` `(unstable s)` | `s` equal / different at `@1` |
| `(signal-width 'tb.sig)`, `(signal? "tb.sig")` | width, existence |
| `(signed sig)` | two's complement of a plain signal name |
| `(sample-at indices)` | resample the trace at these indices (renumbers INDEX!) |
| `(trim-trace 't0 i)` | cut the trace at index `i` |
| `(load "f.vcd" 'tid)` `(unload 'tid)` `(loaded-traces)` | normally done by the script |
| `(defsig name expr)` | virtual signal evaluated on demand |
| `(new-trace id n)` `(dump-trace id)` | build a virtual trace and dump it as VCD (advanced) |

## Scopes and groups

| Form | Notes |
|---|---|
| `(in-scope 'tb.dut expr)` | `~sig` inside means `tb.dut.sig` (quote the scope) |
| `(set-scope tb.dut)` / `(unset-scope)` | persistent scope; argument not quoted here (!) |
| `(all-scopes expr)` | evaluate `expr` in every scope, list of results |
| `(groups "s1" "s2" ...)` | prefixes `p` such that `p+"s1"`, `p+"s2"`... are all signals |
| `(in-group g expr)`, `(in-groups gs expr)` | `#sig` means `g + "sig"` |
| `(groups-excluding (including a b) (excluding c))` | groups with a, b but without c |
| `CS`, `CG` | current scope / group (strings) |

## Core language

| Form | Notes |
|---|---|
| `(define x v)`, `(set [x v] [y w])`, `(set! x v)` | variables; `set` needs an existing binding, `define` fails on an existing one (!); a `set` inside a closure nested in another closure does not reach an outer variable, silently (!) |
| `(let ([a 1] [b 2]) body...)` | local bindings |
| `(defun f [a b] body...)`, `(fn [a] body)` | function; `(fn args body)` with a bare symbol takes a list |
| `(defmacro m [a] body)`, `(macroexpand ...)`, `(gensym)` | macros |
| `(if c a b)`, `(cond [c ...] [else ...])`, `(case x [v ...] ...)`, `(when c ...)`, `(unless c ...)` | |
| `(do a b ...)`, `(while c body...)`, `(until c ...)`, `(for [x l] ...)`, `(for/list [x l] ...)` | `for` returns the last value, `for/list` all |
| `(+ ...)` | numbers add; strings and lists concatenate |
| `(- a b)` `(* a b)` `(/ a b)` `(** a b)` `(mod a b)` `(floor x)` `(ceil x)` `(round x)` | `/` is true division |
| `(= a b)` `(!= a b)` `(< a b)` `(> a b)` `(<= a b)` `(>= a b)` `(&& ...)` `(\|\| ...)` `(! a)` | |
| `(band a b)` `(bor a b)` `(bxor a b)` | bitwise |
| `(list ...)` `(first l)` `(second l)` (no `third`: `l[2]`) `(last l)` `(rest l)` `(length l)` `(in x l)` `(range a b)` `(zip a b)` `(reverse l)` | |
| `(map f l)` `(filter p l)` `(fold f init l)` `(sum l)` `(max l)` `(min l)` `(average l)` `(partition p l)` | `max`/`min`/`average` take one list |
| `(sort l)` | broken in 0.9.1 (!) |
| `(array)` `(array ['k v] ...)` `(seta a k v)` `(geta a k)` `(geta/default a dflt k)` `(dela a k)` `(mapa f a)` | keys are stored as strings |
| `(inc x)` `(dec x)` `(inc-define x)` | increment a variable |
| `(print a b ...)`, `(printf "fmt" a ...)` | `printf` uses Python `%` formatting and no implicit newline |
| `(string->int s base)` `(int->string i)` `(convert/bin i width)` `(bits->sint "bits")` `(string->symbol s)` `(symbol->string 's)` | conversions |
| `(type x)` `(int? x)` `(string? x)` `(list? x)` `(symbol? x)` `(atom? x)` `(defined? 'x)` | |
| `(alias short 'tb.long)`, `(unalias short)` | second argument is evaluated, so quote it |
| `(eval e)`, `(parse "text")`, `(eval-file f)`, `(import ...)`, `(require ...)`, `(module ...)` | modules / files |
| `(call ...)` | call into Python (advanced, see official docs) |
| `(exit n)` | stops the whole script |
