# fpga_scope — Integration guide

How to add the scope to an FPGA design, connect the signals you want to look at, and see them in the GUI.

🧪 Status: the example below has run on one board (Spartan-7, 25 MHz clock, 115200 baud, CP210x adapter): info, capture and stream all worked. 3000 commands without a lost reply, captures and streams matching the example's signals, and the GUI working against the real port. Other boards, clocks and baud rates are untested.

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
| `p_ch0_width` ... `p_ch7_width` | Bits of each channel, 1 to 8 | Width of the signal on that channel. Channels at or above `p_num_channels` are ignored |
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
- One capture must fit in a single reply of at most 65535 bytes, so `samples × bytes per sample` cannot exceed that. Bytes per sample is the sum of the channel widths rounded up to whole bytes. With 8 channels of 8 bits (8 bytes per sample) the largest capture is 8191 samples.
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
  .o_uart_tx(uart_tx_pin)
);
```

All eight `i_chN` ports are always present and always 8 bits wide. The scope only stores the low `p_chN_width` bits of each.

## Step 4 — Connect your signals

Three rules:

1. **Same clock.** Every signal on an `i_chN` port must be synchronous to the `clk` you give the scope. A signal from another clock domain needs a synchroniser first, or you will capture glitches.
2. **Eight bits per channel at most.** Split a wider bus over several channels, for example `i_ch2(counter[7:0])` and `i_ch3(counter[15:8])`. The GUI shows them as two separate traces until you join them: see [Using the GUI](gui.md).
3. **Reset is synchronous and active high.** If your board's reset button is active low, invert it, and pass it through two flip-flops clocked by `clk` first.

The trigger can use any single bit of any channel (rising edge, falling edge, high or low), so put the signal you want to trigger on in a channel too.

## Step 5 — Assign the pins

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

## Step 6 — Build, program and connect

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

To use it:

1. Add `scope_example_top.v` plus the ten files from step 1, and set `scope_example_top` as the top module.
2. Set its two parameters for your board: `p_clk_freq_hz` and `p_uart_preescaler` (defaults: 100 MHz and 868, which is 115200 baud).
3. Constrain the four ports: `clk`, `i_rst` (active high), `i_uart_rx`, `o_uart_tx`.
4. Follow step 6.

What you should see:

- **Scope tab**, trigger `ch0` on *Rising edge*, 100 samples before and 300 after, sampling every clock: ten periods of the fast square with a rising edge exactly on the trigger line, five periods of the slow square, the ramp as a staircase and the triangle as a straight slope (with one turn if a peak falls inside the window). `ch4` stays flat, it is too slow for this window.
- **Stream tab**, sampling every 65535 clocks: `ch4` climbs as a clean ramp. The other four channels look random, because they change far faster than the stream can sample them. That is expected: the live stream is for slow signals, and the Scope tab is for fast ones.

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `info` reports "no response to GET_INFO" | TXD/RXD swapped (step 5); wrong COM port; baud rate does not match `p_uart_preescaler`; the scope is held in reset; `scope_defs.vh` was not found during the build |
| Garbage or only occasional replies | Baud rate mismatch (recompute step 2 with the real clock frequency) |
| "ARM rejected" or "SET_TRIGGER rejected" from the command line | A finished capture stays loaded until it is aborted: run `python scope_cli.py ... abort`. The GUI and the `capture` command do this for you |
| Stays "Armed, waiting for trigger" | The trigger condition never happens. Try a level trigger on a signal you know is active, and check which bit is selected on multi-bit channels |
| The time axis is wrong | `p_clk_freq_hz` does not match the real clock |
| The capture shows glitches that are not in the design | The signal is not synchronous to the scope's `clk` (step 4, rule 1) |

## Known limitations

- The simulated device (`sim`) imitates the protocol, not the UART timing or the RTL, so a design that works against it still has to be checked on the board.
- The live stream has no guaranteed sample rate: it sends one sample, waits for the UART, then waits the decimation count again.
