# fpga_scope — Integration guide

How to add the scope to an FPGA design, connect the signals you want to look at, and see them in the GUI.

🧪 Status: the example below has run on one board (Spartan-7, 25 MHz clock, 115200 baud, CP210x adapter): info, capture and stream all worked. 3000 commands without a lost reply, captures and streams matching the example's signals, and the GUI working against the real port. Other boards, clocks and baud rates are untested. The controls (step 5) came after that run: they are verified in simulation, and the user tried the buttons from the GUI on the board (2026-10-12) and they worked; what exactly was checked was not written down. The two channels the example gained to show them have only been simulated.

## What you need

- A free pair of FPGA pins wired to a USB-UART adapter (FTDI or similar). Many boards already have one on the USB port.
- One clock. The scope samples your signals on that clock.
- Python 3 on the computer, with the backend dependencies: `pip install -r gui/backend/requirements.txt`.

## Step 1 — Add the files to your project

Ten files, from two places in this repository:

| Files | From |
|-------|------|
| `scope_top.v`, `scope_cmd_if.v`, `scope_ctrl.v`, `scope_trigger.v`, `scope_decimator.v`, `scope_streamer.v`, `scope_capture_buffer.v` | `utils/fpga_scope/source/` |
| `scope_defs.vh` (header, `` `include``d by the files above) | `utils/fpga_scope/source/` |
| `uart_tx.v`, `uart_rx.v` | `modules/uart/source/` |

`scope_defs.vh` is not a module: add it as a Verilog header, or put its folder on the include path. With the [Vivado scripts](../../Scripts_Vivado_Workflow/vivado.md) of this repository, the `.v` files go in `source/` and `scope_defs.vh` in `include/`.

## Step 2 — Choose the parameters

| Parameter | Meaning | How to choose it |
|-----------|---------|------------------|
| `p_num_channels` | Number of channels, 1 to 8 | One channel per signal (or bus) you want to see |
| `p_channel_max_width` | Width of the `i_chN` ports, 1 to 16, the same for all eight. Default 8 | Leave it at 8 unless a signal is wider than 8 bits. With 16, a 16-bit signal fits on one channel |
| `p_ch0_width` ... `p_ch7_width` | Bits of each channel, 1 to `p_channel_max_width` | Width of the signal on that channel. Channels at or above `p_num_channels` are ignored |
| `p_buffer_depth_log2` | Capture buffer holds `2^N` samples | `10` (1024 samples) is a good start. See the two limits below |
| `p_uart_preescaler` | Clock cycles per UART bit | `clock frequency / baud rate`, rounded. See the table below |
| `p_clk_freq_hz` | Frequency of `clk`, in Hz | Only reported to the GUI, which uses it for the time axis |

**Baud rate.** The scope has no autobaud: the value you compute here is the baud rate you must select in the GUI.

| Clock | `p_uart_preescaler` for 115200 baud |
|-------|-------------------------------------|
| 12 MHz | 104 |
| 25 MHz | 217 |
| 50 MHz | 434 |
| 100 MHz | 868 |
| 125 MHz | 1085 |

Start with 115200. A faster rate only makes dumps and the live stream quicker, and is only worth trying when `clock frequency / baud rate` comes out very close to a whole number.

**Buffer limits.**

- The buffer uses `2^p_buffer_depth_log2 × (sum of the channel widths)` bits of block RAM. Example: 1024 samples of 22 bits = 22.5 kbit.
- One capture must fit in a single reply of at most 65535 bytes, so `samples × bytes per sample` cannot exceed that. Bytes per sample is the sum of the channel widths rounded up to whole bytes. With 8 channels of 8 bits (8 bytes per sample) the largest capture is 8191 samples; with 8 channels of 16 bits (16 bytes per sample) it is 4095, so keep `p_buffer_depth_log2` at 11 or below for that build.
- Keep `p_buffer_depth_log2` at 15 or below.

## Step 3 — Instantiate `scope_top`

```verilog
scope_top # (
  .p_num_channels(3),
  .p_ch0_width(1),
  .p_ch1_width(1),
  .p_ch2_width(8),
  .p_buffer_depth_log2(10),         /* 1024 samples */
  .p_uart_preescaler(868),          /* 100 MHz / 115200 baud */
  .p_clk_freq_hz(32'd100_000_000)
) scope (
  .clk(clk),
  .rst(rst),                        /* synchronous, active high */
  .i_ch0({7'd0, my_valid}),         /* 1-bit signal: pad the unused upper bits with zeros */
  .i_ch1({7'd0, my_ready}),
  .i_ch2(my_data),                  /* 8-bit signal */
  .i_ch3(8'd0),                     /* unused channels: tie to zero */
  .i_ch4(8'd0),
  .i_ch5(8'd0),
  .i_ch6(8'd0),
  .i_ch7(8'd0),
  .i_uart_rx(uart_rx_pin),          /* straight from the pin, synchronised inside the scope */
  .o_uart_tx(uart_tx_pin),
  .o_control0(),                    /* controls: values written from the GUI, see step 5. */
  .o_control1(),                    /* Leave them open if you do not use them */
  .o_control2(),
  .o_control3(),
  .o_control4(),
  .o_control5(),
  .o_control6(),
  .o_control7(),
  .o_control_update()
);
```

All eight `i_chN` ports are always present and always `p_channel_max_width` bits wide (8 unless you set it). The scope only stores the low `p_chN_width` bits of each.

With `p_channel_max_width(16)` the ports are 16 bits wide, so padding and tie-offs change to match: `.i_ch0({15'd0, my_valid})`, `.i_ch3(16'd0)`.

## Step 4 — Connect your signals

Three rules:

1. **Same clock.** Every signal on an `i_chN` port must be synchronous to the `clk` you give the scope. A signal from another clock domain needs a synchroniser first, or you will capture glitches.
2. **`p_channel_max_width` bits per channel at most** (8 by default, up to 16). Either set `p_channel_max_width(16)`, or split a wider bus over several channels, for example `i_ch2(counter[7:0])` and `i_ch3(counter[15:8])`. Split channels show as two separate traces until you join them in the GUI: see [Using the GUI](gui.md). Splitting also works for values wider than 16 bits.
3. **Reset is synchronous and active high.** If your board's reset button is active low, invert it, and pass it through two flip-flops clocked by `clk` first.

The trigger can use any single bit of any channel (rising edge, falling edge, high or low), so put the signal you want to trigger on in a channel too.

## Step 5 — Controls (optional)

The scope can also write to your design. It has eight 32-bit outputs, `o_control0` to `o_control7`, which hold whatever was last written to them from the GUI (or `scope_cli.py control`), and are 0 after reset. There is nothing to configure in the FPGA: all eight are always there, you connect the ones you want and leave the rest open. In the GUI you then say what each one is (a button, a switch or a number) and give it a name; a design that uses none simply leaves them all as *Not used*.

```verilog
wire [31:0] w32_speed;
wire [31:0] w32_enable;
wire [7:0]  w8_control_update;

scope_top # ( ... ) scope (
  ...
  .o_control0(w32_enable),          /* a switch in the GUI: 1 or 0 */
  .o_control1(w32_speed),           /* a value in the GUI */
  .o_control2(),                    /* a button in the GUI: only its pulse is used, below */
  ...
  .o_control_update(w8_control_update)
);

assign motor_enable = w32_enable[0];
assign speed_setpoint = w32_speed[15:0];        /* use the bits you need */
assign start_pulse = w8_control_update[2];      /* one clock, every time the button is pressed */
```

- **A level**: `o_controlN` keeps the value until the next write. All its bits change in the same clock, so a multi-bit value is never seen half written.
- **A pulse**: `o_control_update[N]` is high for one clock on every write to control N, also when the value does not change. Use it for anything that should happen once per press.
- They are synchronous to the scope's `clk`, like the channels.
- To see a control next to what it causes, also connect it to a channel: `.i_ch5(w32_speed[7:0])`.

Three things to know:

1. **A write is not instant.** It travels over the UART, so it arrives milliseconds after the click, and not at a predictable clock cycle.
2. **Not during a transfer.** While a capture is being uploaded or a stream burst is being sent, the core does not listen. The GUI holds the write until the burst in flight has finished, so on the Stream tab with large bursts a button reacts with a delay.
3. **The value stays.** There is no timeout: if the GUI is closed or the cable is pulled, every control keeps its last value until the FPGA is reset. Do not let a control be the only thing that keeps a motor, a heater or anything else that can do damage within safe limits. Put the limit in the design.

## Step 6 — Assign the pins

The names are from the FPGA's point of view, so they cross over at the adapter:

| Scope port | Connects to |
|------------|-------------|
| `i_uart_rx` | the adapter's **TXD** (data from the computer) |
| `o_uart_tx` | the adapter's **RXD** (data to the computer) |

Example Vivado constraints (replace the pin names and I/O standard with your board's):

```tcl
set_property -dict { PACKAGE_PIN A9  IOSTANDARD LVCMOS33 } [get_ports i_uart_rx]
set_property -dict { PACKAGE_PIN D10 IOSTANDARD LVCMOS33 } [get_ports o_uart_tx]
```

## Step 7 — Build, program and connect

1. Build the bitstream and program the FPGA.
2. First check the link from the command line, from `utils/fpga_scope/gui/backend/`:

   ```bash
   python scope_cli.py --port COM5 --baud 115200 info
   ```

   It should print the channel count, widths, buffer depth and clock frequency you configured. If it does, the UART works in both directions.
3. Start the GUI backend and open http://127.0.0.1:8000:

   ```bash
   python app.py
   ```

4. Select your COM port and baud rate, click **Connect**, choose a trigger and click **Arm**.

You can try the GUI before the hardware is ready: the port list always contains a simulated device (`sim`).

## Complete example

[`example/scope_example_top.v`](../example/scope_example_top.v) is a full top level that needs nothing but a clock, a reset and the two UART pins. It generates its own signals, so it is the quickest way to check a board:

| Channel | Width | Signal |
|---------|-------|--------|
| ch0 | 1 bit | square wave, period 40 clocks |
| ch1 | 1 bit | square wave, period 80 clocks |
| ch2 | 4 bits | ramp 0 to 15, one step every 8 clocks |
| ch3 | 8 bits | triangle 0 to 255 and back, one step every clock |
| ch4 | 8 bits | slow ramp, one step every 65536 clocks |
| ch5 | 8 bits | the low byte of control 0 |
| ch6 | 1 bit | toggles on every write to control 0 |

To use it:

1. Add `scope_example_top.v` plus the ten files from step 1, and set `scope_example_top` as the top module.
2. Set its two parameters for your board: `p_clk_freq_hz` and `p_uart_preescaler` (defaults: 100 MHz and 868, which is 115200 baud).
3. Constrain the four ports: `clk`, `i_rst` (active high), `i_uart_rx`, `o_uart_tx`.
4. Follow step 7.

What you should see:

- **Scope tab**, trigger `ch0` on *Rising edge*, 100 samples before and 300 after, sampling every clock: ten periods of the fast square with a rising edge exactly on the trigger line, five periods of the slow square, the ramp as a staircase and the triangle as a straight slope (with one turn if a peak falls inside the window). `ch4` stays flat, it is too slow for this window.
- **Stream tab**, sampling every 65535 clocks: `ch4` climbs as a clean ramp. `ch0` to `ch3` look random, because they change far faster than the stream can sample them. That is expected: the live stream is for slow signals, and the Scope tab is for fast ones.
- **Controls**: in the GUI's **Controls** panel (right of the plot, under **Set up**) set control 0 to *Value*, start the stream, type a number from 0 to 255 and click **Send**: `ch5` steps to that number and `ch6` changes level. Send the same number again: `ch5` stays and `ch6` changes level again. From the command line, `python scope_cli.py --port COM5 --baud 115200 control 0 42` followed by `controls` does the same check without the GUI.

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `info` reports "no response to GET_INFO" | TXD/RXD swapped (step 6); wrong COM port; baud rate does not match `p_uart_preescaler`; the scope is held in reset; `scope_defs.vh` was not found during the build |
| Garbage or only occasional replies | Baud rate mismatch (recompute step 2 with the real clock frequency) |
| "ARM rejected" or "SET_TRIGGER rejected" from the command line | A finished capture stays loaded until it is aborted: run `python scope_cli.py ... abort`. The GUI and the `capture` command do this for you |
| Stays "Armed, waiting for trigger" | The trigger condition never happens. Try a level trigger on a signal you know is active, and check which bit is selected on multi-bit channels |
| The time axis is wrong | `p_clk_freq_hz` does not match the real clock |
| The capture shows glitches that are not in the design | The signal is not synchronous to the scope's `clk` (step 4, rule 1) |
| The controls are greyed out with "The connected core has no controls" | The bitstream was built from scope RTL older than the controls: `info` reports protocol version 1. Copy the current `source/` files into the project and rebuild |
| A button reacts late on the Stream tab | The write waits for the burst in flight (step 5). Use fewer samples per burst |

## Known limitations

- The simulated device (`sim`) imitates the protocol, not the UART timing or the RTL, so a design that works against it still has to be checked on the board.
- The live stream has no guaranteed sample rate: it sends one sample, waits for the UART, then waits the decimation count again.
