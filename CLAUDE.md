# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A personal learning handbook for digital design and verification: Markdown notes plus a small library of reusable Verilog modules, each with its own testbench. The Markdown is converted to a static website that is committed under `publish/`.

- `design/`, `verification/`, `others/` — theory notes (Markdown only, plus cocotb/UVM examples).
- `modules/<name>/` — reusable RTL: `source/*.v`, `test/<name>_tb.{v,sv}` + `test/run.py`, and a `<name>.md` doc page.
- `utils/` — tooling write-ups (Pico JTAG, Vivado TCL flow, Qt GUI) and `utils/fpga_scope/`, an FPGA debug scope with its own RTL, Python backend and web GUI.
- `web/` — the two scripts that build the site into `publish/`.
- `publish/` — **generated output, never edit by hand** (except `index.html`, `nav.html`, `styles.css`, which exist only there and are maintained manually).

## Commands

Toolchain is Icarus Verilog (`iverilog`/`vvp`) + GTKWave, on Windows. `pandoc`, `make` and `cocotb-config` are not on PATH on this machine, so the web build and the cocotb examples cannot be run here without installing them.

### Run a module testbench

Each module has a `run.py` that must be run **from its own `test/` directory** (all paths in it are relative):

```bash
cd modules/uart/test && python run.py
```

It compiles with `iverilog -g2005-sv -gstd-include -grelative-include -s <tb_top>`, runs `vvp -l sim_log`, and leaves `sim_log` and `<tb>.vcd` next to the testbench. `run.py` prints the two process exit codes (`0` / `0`); it does not judge pass/fail — read the simulator output for `$error` lines. The `run.py` files are copies of each other differing only in the source list, testbench file and top-level name; a new module gets a copy with those three edited.

`modules/modulador_2lvl/test/run.py` has `SOURCES_DIR = "../../source/"`, which does not resolve from its `test/` directory (the other modules use `../source/`).

### Run the fpga_scope tests

```bash
cd utils/fpga_scope/test && python run.py        # RTL; success is the final line "[PASS] All checks passed."
cd utils/fpga_scope/test && python run_wide.py   # the same core built with 16-bit channels (p_channel_max_width = 16)
cd utils/fpga_scope/gui/backend
python -m unittest test_protocol test_scope_cli test_app    # one module: python -m unittest test_protocol
python -m unittest test_frontend    # the web page in a headless Chrome/Edge, ~5 s; skipped if no browser is found
```

`run.py` leaves `sim_log` and `scope_tb.vcd` behind (`run_wide.py`: `scope_wide_tb.vcd`); all gitignored (the VCD is ~500 KB and was deliberately removed from history once).

The UART has a second testbench, `modules/uart/test/run_async.py` (`uart_async_tb.v`): transmitter and receivers on unrelated clocks, 2 % apart. `uart_tb.v` shares one clock and reset between both ends and cannot catch timing bugs that only show on a real link.

### cocotb examples

`verification/cocotb/{Simple_tb,Complex_tb}/` use the standard cocotb Makefile flow (`make` in that directory, `SIM = icarus`).

### Build the website

Both scripts use paths relative to `web/`, so run them from there. Requires `pandoc`.

```bash
cd web
python generate_srcs.py --only   # prompts for a directory (e.g. ../modules/uart/) and a file name without extension
python generate_srcs.py --all    # regenerates every .md in the repo; prompts, answer "S" to continue
python publish.py                # copies the tree into ../publish
python -m http.server 8000       # run from publish/ to preview (nav.html is loaded with fetch, so file:// won't work)
```

`generate_srcs.py` writes each `.html` next to its `.md` (those are gitignored), rewrites `.md` links to `.html`, and injects the `nav.html` loader after `<body>`. `publish.py` then copies everything into `publish/`, skipping `.md`, `.vcd`, `.gtkw`, `.tcl`, `.bat`, `sim_log`, `__pycache__`, `web/` and `program_files/`. A new page therefore needs its HTML generated before publishing, and `publish/index.html` and `publish/nav.html` must be updated by hand — neither is automated.

## Conventions

### RTL naming

The existing modules share a prefix scheme; follow it in new RTL:

- Parameters `p_*`, localparams `lp_*` (`lpw_*` for a derived width), FSM states `st_*`.
- Ports: `i_*` / `o_*`; `or_*` for a registered output; `ip_*` / `orp_*` when the width is parameter-dependent.
- Internals: `r_*` regs, `w_*` wires, with the bit width embedded when fixed (`r3_state`, `r16_data_index`, `w8_rx_byte`) and `p` when parameterised (`rp_data`).
- `rst` is a **synchronous**, active-high reset everywhere. Comments are `/* ... */`, indentation is 2 spaces.

### Module documentation

Every module page (`modules/uart/uart.md` is the template) has: a short description, a `✔️ Verified via testbench …` line, a `🧪 Status:` line, source and testbench links, and an empty-port instantiation snippet. The status line is explicit about **simulation-only vs tested on real hardware** — never claim hardware testing that has not happened.

Modules are versioned one by one (scheme in `modules/modules.md`, "Releases"): the page has a `🏷️ Version` line and a changelog at the end, and each release is a tag `<module>/vX.Y.Z` on `main`. A change to a versioned module bumps its version and adds a changelog entry; tag it once it is on `main`. Modules from before the scheme have no version yet.

A new module or page is also added to its section index (`modules/modules.md`, `utils/utils.md`, …) and to the index in the root `README.md`.

## fpga_scope (`utils/fpga_scope/`)

A project-agnostic FPGA debug oscilloscope: an RTL core driven over UART, a Python backend (`gui/backend/`) and a plain HTML/JS/CSS frontend with no build step (`gui/frontend/`). It works on real hardware (one board and configuration tested, recorded in `docs/TODO.md`). `fpga_scope.md` is the user-facing page.

Besides reading signals it writes to the design: 8 "controls", 32-bit registers on `scope_top`'s `o_control0`..`o_control7` with a one-clock `o_control_update` pulse per write, shown in the GUI as buttons, switches or values. The core always has all 8 (no parameter, a user decision); how many are used and what they are is GUI configuration only. They are called "control", never "ctrl": `scope_ctrl` and `w_ctrl_*` are the capture state machine.

GUI layers, bottom up: `protocol.py` (wire protocol, `ScopeClient`) → `session.py` (one connection plus its background capture/stream job, no web dependency) → `app.py` (FastAPI: REST for commands, one WebSocket for pushed state and data) → `gui/frontend/app.js` (page, drawing, interaction) on top of `gui/frontend/scope_math.js` (everything that needs no page: configuration, scaling, combining channels, axes, zoom, file formats). `scope_cli.py` is the command-line bring-up tool. `sim_device.py` is a simulated core that takes the place of the serial port (port name `sim`; `sim-fsm`, with state machines on its channels, to go with `gui/examples/sim-fsm.json`; and the unlisted `sim-v1` for a core built before the controls existed); it is a stand-in for GUI work, not a reference model of the RTL, and it hid a real RTL bug once, so a change is only verified by `scope_tb.v` and, for timing or UART matters, by the board.

```bash
cd utils/fpga_scope/gui/backend
pip install -r requirements.txt
python app.py                                         # then open http://127.0.0.1:8000 and pick the "sim" port
python scope_cli.py --port COM5 --baud 115200 info    # first check against a real board
```

There is no Node on this machine and no build step, so the frontend tests are pages: `gui/frontend/tests/unit.html` (tests `scope_math.js`) and `tests/e2e.html` (drives the real `index.html` in an iframe against the `sim` port). `test_frontend.py` serves them from `app.py`, opens them headless and collects the result they POST back. New display logic goes in `scope_math.js` with a test in `tests/unit.js`; new page behaviour gets a step in `tests/e2e.js`. `app.js` keeps its state in top-level `const`/`let`, which the e2e test reads with the iframe's `eval`.

The GUI configuration (per-channel display settings, trigger, window) is defined only in the frontend (`ScopeMath.defaultConfig` / `normalizeConfig`); the backend stores it as opaque JSON in `gui/configs/` (gitignored). A new setting needs: the default and its validation in `scope_math.js`, a row in `CHANNEL_FIELDS` (or `CONTROL_FIELDS`) in `app.js`, and the key table in `docs/gui.md`.

Read these before touching it:

- `docs/protocol.md` — the host↔FPGA wire protocol, implemented independently by the RTL and by `protocol.py`. A protocol change means updating the doc, `source/scope_defs.vh`, `source/scope_cmd_if.v`, `protocol.py` and `sim_device.py` together.
- `docs/TODO.md` — status, verification record, remaining work, and a "Design decisions already made" section recording choices the user made explicitly (separate `p_chN_width` parameters and `i_chN` ports rather than packed buses, count-bounded stream bursts, no Qt and no build step for the GUI, etc.). Respect those; keep the file updated as work progresses.
- `docs/integration.md` — the user's step-by-step guide; keep it in step with parameter or port changes.
- `docs/gui.md` — how to use the GUI, and the configuration file format (users write these by hand).

Structure: `scope_top` packs the 8 channel inputs (`p_channel_max_width` bits each, 8 by default, up to 16) down to the configured widths (channel 0 at the LSB) and wires together `scope_decimator` (sample-rate divider), `scope_trigger`, `scope_ctrl` (capture FSM: idle → armed → capturing → done), `scope_capture_buffer` (ring buffer), `scope_streamer` (stream mode) and `scope_cmd_if` (frame parser/responder, by far the largest block). `scope_cmd_if` instantiates `uart_tx`/`uart_rx` from `modules/uart/source/` with `p_data_buffer(1)`, so **fpga_scope depends on the shared UART modules** — a change to those needs `modules/uart/test/run.py`, `run_async.py` and `scope_tb.v` re-run.

The RTL is copied by hand into the projects that use it (currently `Documents/Drone/Firmware/FPGA_SOM/source/`, with `scope_defs.vh` in its `include/`). After an RTL fix here, those copies are stale until re-copied and rebuilt.

Things that are easy to get wrong:

- `scope_capture_buffer`'s read data is registered (BRAM-style), valid one cycle after `rd_en`/`rd_addr`.
- `scope_ctrl` stays in `SCOPE_ST_DONE` after a capture; `CMD_SET_TRIGGER`, `CMD_ARM` and `CMD_SET_MODE` are rejected until a `CMD_ABORT` returns it to idle.
- `scope_ctrl` ignores triggers until the pre-trigger window is full; a test that arms and triggers immediately must wait for it.
- `(pre_trigger_count + post_trigger_count) * frame_bytes` must fit the 16-bit `LEN` field.
- A capture window of the whole buffer comes back with sample 0 overwritten by the newest sample: at decimation 1, `scope_ctrl` writes the trigger sample on top of `post`. It is a known bug, deliberately left in the RTL (user, 2026-10-15). The hosts keep `pre + max(post, 1) <= depth - 1` in two places that must agree: `ScopeInfo.capture_window_fits` in `protocol.py` and `ScopeMath.captureWindowFits` in `scope_math.js`. See "Known issues" in `docs/TODO.md`.
- Sample registers that are byte-indexed (`[8*idx +: 8]`) must be declared `frame_bytes*8` wide, not `frame_width` wide, or the padding bits read back as X.
- Both `MODE_SCOPE` and `MODE_STREAM` are always built in; there are no build-time mode enables.
- While a dump or stream burst is in flight the core only processes `CMD_ABORT`. A control write sent then is dropped, so `session.py` slots it between two exchanges of the running job (`_call` / `_job_call`); anything else that talks to the device while a job runs must go through the same pair.
- A core built before the controls reports `protocol_version` 1 and ignores their opcodes without answering: check `ScopeInfo.num_controls` before sending one.
- `.gitignore` ignores `*.html` and `*.css` repo-wide (generated site pages); `gui/frontend/` is explicitly un-ignored there. A new frontend file type or folder needs the same treatment or it will silently stay out of commits.
