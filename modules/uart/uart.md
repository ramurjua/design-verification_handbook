### 🔹 UART Transmitter

Sequential module that transmits data serially using the UART protocol.

✔️ Verified via testbench with stimuli for various baud rates, frame sizes, and transmitted values.

🧪 Status: Reworked on 2026-10-10 (bit timing restarts on every start bit, mid-bit sampling in the receiver). The reworked version is verified in simulation, including a link with mismatched clocks ([testbench](test/uart_async_tb.v)), and tested on real hardware one byte at a time (`p_data_buffer = 1`) at 115200 baud with a 25 MHz clock and a CP210x USB-UART adapter; multi-byte buffers are simulation only.

📁 [Source Code](source/uart_tx.v)

📁 [Testbench](test/uart_tb.v)

📌 Instantiation:

```verilog
uart_tx # (
    .p_preescaler(), /* Clock prescaler to set baudrate */
    .p_data_buffer() /* Number of bytes to send */
) uart_tx (
    .clk(), 
    .rst(), /* Synchronous reset */
    .ip_data(), /* Data to send */
    .i_dv(), /* Input data valid */
    .o_ready(), /* Module ready to accept new data */
    .o_tx() /* UART transmission line */
);
```

### 🔹 UART Receiver

Sequential module that receives data serially using the UART protocol.

✔️ Verified via testbench with stimuli for various baud rates, frame sizes, and transmitted values.

🧪 Status: Reworked on 2026-10-10 (bit timing restarts on every start bit, mid-bit sampling in the receiver). The reworked version is verified in simulation, including a link with mismatched clocks ([testbench](test/uart_async_tb.v)), and tested on real hardware one byte at a time (`p_data_buffer = 1`) at 115200 baud with a 25 MHz clock and a CP210x USB-UART adapter; multi-byte buffers are simulation only.

📁 [Source Code](source/uart_rx.v)

📁 [Testbench](test/uart_tb.v)

📌 Instantiation:

```verilog
uart_rx #(
    .p_preescaler(), /* Prescaler for baudrate */
    .p_data_buffer() /* Indicates number of bytes to receive */
) uart_rx (
    .clk(), /* Input clock */
    .rst(), /* Input reset */
    .i_rx(),	/* Input RX pin */
    .orp_data(),	/* Parallel data port */
    .or_dv() /* New data available in data port */ 
);
```

### 🔹 Notes

- The baud rate is `clock frequency / p_preescaler`. Example: 25 MHz and `p_preescaler = 217` give 115200 baud.
- Frame format is 8N1. With `p_data_buffer` greater than 1 the bytes go out, and are assembled, most significant byte first.
- The receiver synchronises `i_rx` internally, so the pin can be connected directly.
- Two testbenches: `test/run.py` (both ends on one clock) and `test/run_async.py` (receivers on clocks 2 % faster and slower than the transmitter, bytes at random moments).
