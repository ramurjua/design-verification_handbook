### 🔹 SPI Master

Module that transmits and reads data using the SPI protocol actuating as a master. Take into account chip select logic is outside the modules scope since it can be different depending on its use. 

✔️ Verified via testbench with stimuli for various clock preescalers, cpol configurations, frame sizes, and transmitted values.

🧪 Status: Tested on real hardware using components in PCB that communicates through SPI.

📁 [Source Code](source/spi_master.v)

📁 [Testbench](test/spi_tb.v)

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

📁 [Source Code](source/spi_slave.v)

📁 [Testbench](test/spi_tb.v)

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