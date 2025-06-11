# Code Modules

This section contains digital design modules that have been successfully developed, verified, and tested. The goal is to build a reusable library that can be easily integrated into future personal or professional projects.

## 📦 Available Modules

### 🔹 UART Transmitter

Sequential module that transmits data serially using the UART protocol.

✔️ Verified via testbench with stimuli for various baud rates, frame sizes, and transmitted values.

🧪 Status: Tested on real hardware using an FTDI connected to a computer.

📁 [Source Code](uart/source/uart_tx.v)

📁 [Testbench](uart/test/uart_tb.v)

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

📁 [Source Code](uart/source/uart_rx.v)

📁 [Testbench](uart/test/uart_tb.v)

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

### 🔹 SPI Master

Module that transmits and reads data using the SPI protocol actuating as a master. Take into account chip select logic is outside the modules scope since it can be different depending on its use. 

✔️ Verified via testbench with stimuli for various clock preescalers, cpol configurations, frame sizes, and transmitted values.

🧪 Status: Tested on real hardware using components in PCB that communicates through SPI.

📁 [Source Code](spi/source/spi_master.v)

📁 [Testbench](spi/test/spi_tb.v)

📌 Instantiation:

```verilog
spi_master #(
    .p_prescaler(), /* spi clock prescaler */
    .p_cpol(),	/* clock polarity */
    .p_max_data_buffer(), /* Max data buffer in bits */
    .pw_data_index() /* Width for data index */
) spi_master (
    .clk(),
    .rst(),
    .ip_data(), /* parallel data to send */
    .ip_data_count(), /* number of bits to send */
    .i_data_valid(), /* input data ready to send */
    .orp_data(), /* parallel data readed */
    .o_data_ready(), /* SPI module ready to receive data */
    .or_mosi(), /* master output, slave input pin */
    .i_miso(), /* master input, slave output pin */
    .o_sck() /* spi clock pin */
);
```

### 🔹 SPI Slave

Module that transmits and reads data using the SPI protocol actuating as a slave. Take into account chip select logic is outside the modules scope since it can be different depending on its use. 

✔️ Verified via testbench with stimuli for various clock preescalers, cpol configurations, frame sizes, and transmitted values.

🧪 Status: Tested on real hardware using a MCU as master and the FPGA as Slave.

📁 [Source Code](spi/source/spi_slave.v)

📁 [Testbench](spi/test/spi_tb.v)

📌 Instantiation:

```verilog
spi_slave #(
    .p_data_buffer_length(), /* input data buffer length */
    .p_cpol() /* clock polarity */
) spi_slave (
    .clk(),
    .rst(),
    .ip_data_out(), /* data to send */
    .ip_data_count(), /* data bit count */
    .op_data_in(), /* data received */
    .o_data_valid(), /* new transaction finished */
    .o_busy(), /* spi interface is busy */
    .i_sclk(), /* spi sclk input */
    .i_mosi(), /* spi mosi input */
    .or_miso() /* spi miso output */
);
```
