# ✅ Code Modules

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

### 🔹 Clark Park

Module that performs the clark-park transformation, based on the following equations:

Amplitud invariant Clark transformation:

\begin{bmatrix} Valfa \\ Vbeta \end{bmatrix} = 2/3 \begin{pmatrix} 1 & -1/2  & -1/2  \\ 0 & \sqrt{3}/2  & -\sqrt{3}/2 \end{pmatrix} \cdot \begin{bmatrix} Va \\ Vb \\ Vc \end{bmatrix}


Park Transformation:

\begin{bmatrix} Vd\\ Vq\end{bmatrix} = \begin{pmatrix} cos(\Theta) & sin(\Theta)   \\ -sin(\Theta) & cos(\Theta) \end{pmatrix} \cdot \begin{bmatrix} Valfa \\ Vbeta \end{bmatrix} 

✔️ Verified via testbench.

🧪 Status: Tested on real hardware controlling a motor.

📁 [Source Code](clarkpark/source/clarkpark.v)

📁 [Testbench](clarkpark/test/clark_park_tb.sv)

📌 Instantiation:

```verilog
clarkpark # (
    .pw_io_width(), /* total input and output width */
    .pw_io_decimal_width(), /* input and output decimals width */
    .p_2div3(), /* 2/3 fixed point value (0.666 * 2^pw_io_decimal_width) */
    .p_sqrt3div3(), /* sqrt(3)/3 fixed point value (0.577 * 2^pw_io_decimal_width) */
    .p_1div3() /* 1/3 fixed point value (0.333 * 2^pw_io_decimal_width) */
  ) clarkpark_inst ( 
    .clk(), 
    .reset(), 
    .isp_a(), /* input a signal */
    .isp_b(), /* input b signal */
    .isp_c(), /* input c signal */
    .ip_sine(), /* angle sine */
    .ip_cosine(), /* angle cosine */
    .osp_d(), /* output d signal */
    .osp_q() /* output q signal */
);
```

### 🔹 Clark Park Inverse

Module that performs the clark-park inverse transformation, based on the following equations:

Park inverse transformation:

\begin{bmatrix} Valfa\\ Vbeta\end{bmatrix} = \begin{pmatrix} cos(\Theta) & -sin(\Theta)   \\sin(\Theta) & cos(\Theta) \end{pmatrix} \cdot \begin{bmatrix} Vd \\ Vq \end{bmatrix} 

Clark inverse transformation:

\begin{pmatrix} Va \\ Vb \\ Vc \end{pmatrix} = \begin{pmatrix} 1 & 0 \\ -1/2 & \sqrt{3}/2 \\ -1/2 & -\sqrt{3}/2 \end{pmatrix} \cdot \begin{pmatrix} Valfa \\ Vbeta \end{pmatrix}

✔️ Verified via testbench.

🧪 Status: Tested on real hardware controlling a motor.

📁 [Source Code](clarkpark/source/clarkpark_inv.v)

📁 [Testbench](clarkpark/test/clark_park_tb.sv)

📌 Instantiation:

```verilog
clarkpark_inv # (
    .pw_io_width(), /* total input and output width */
    .pw_io_decimal_width(), /* input and output decimals width */
    .p_sqrt3div2() /* sqrt(3)/2 fixed point value (0.866 * 2^pw_io_decimal_width) */
  ) clarkpark_inv_inst (
    .clk(),
    .reset(),
    .ip_sine(),
    .ip_cosine(),
    .isp_d(),
    .isp_q(),
    .osp_a(),
    .osp_b(),
    .osp_c()
);
```
### 🔹 DDS

Module that generates sin and cos waveforms of selected frequency.

✔️ Verified via testbench as an auxliar module used in clark park verification.

🧪 Status: Tested on real hardware to generate waveforms as modulators for a motor.

📁 [Source Code](clarkpark/source/dds.v)

📁 [Testbench](clarkpark/test/clark_park_tb.sv)

📌 Instantiation:

```verilog
dds dds_inst(
    .clk(), 
    .rst(), 
    .i12_period(), /* sinusoidal period -> i12_period = fclk / (sin_freq * 4096) */
    .or12_angle(), /* angle generated */
    .ors16_sin(), /* sin signal in format S[16,15] */
    .ors16_cos() /* cos signal in format S[16,15] */
);
```