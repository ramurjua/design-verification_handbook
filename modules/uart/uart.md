### 🔹 UART Transmitter

Sequential module that transmits data serially using the UART protocol.

✔️ Verified via testbench with stimuli for various baud rates, frame sizes, and transmitted values.

🧪 Status: Tested on real hardware using an FTDI connected to a computer.

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

🧪 Status: Tested on real hardware using an FTDI connected to a computer.

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