# High Level Synthesis

## Introduction to HLS

Synthesize an algorithm model of an IP Core wirtter in C/C++ into a Register-Transfer-Level architecture. 

Generate different RTL architectures using directives and constrains. Explore the trade-off between FPGA resource usage and perormanece. *Design Space Exploration*

* Rolled loop: default design. Series implementation, sharing resources.
* Unrolled loop: Parallel, increasing resources and registering outputs.
* Pipelined design: Adding registers to increase throughput.

Is useful to move C code (running in a processor for example) to hardware. Mainly useful in algorithm but not for logic, state-machines should be human-coded to achieve good results. It is hardware generation so you should take into account all the hardware problems such a clock domains...

### Resources and Performance Estimation

T: clock period
II: Initiation invervale

Latency (L): number of clks it takes grom the input values until you get the corresponding output values. 

L = II - 1

Throughput: frequency with we can apply new input values (and output values are valid).

D = 1/ (II * T)

Relative resource usage Rg:

Rg = (BRAM / BRAMmax + DSP/DSPmax + FF/FFmax + LUT/LUTmax) / 4

Trade-off Latency vs Rosurces: Rg x L aprox const

### HLS Workflow

1. C Simulation 

In terms of C code, an IP is a function. You can use classes or other functions inside but the top should be a C function. 

Write a self-checking testbench. Your have to write a C testbench. Model-based testing: matlab golden model, C test by comparsion and generates a Verilog test by comparison with C results. The main funtion must return 0 if success and 1 otherwise. 

2. C Synthesis

Configure project sol1_config.cfg in settings folder. 

```
part=xc7a35ttcpg236-1

[hls]
flow_target=vivado
package.output.format=ip_catalog
package.output.syn=false
syn.top=fir
syn.file=../src/fir.c
tb.file=../src/fir_test.c
tb.file=../src/output.gold.dat
clock=10ns
clock_uncertainty=10%
csim.code_analyzer=0
syn.compule.pipelin_loops=0
syn.compile.enable_auto_rewind=0
cosim.trace_level=port
cosim.wave_debug=1
```
Results: Reports

Timming Estimate -> critical path and comparison to target clock=10ns
Performce & Rssource Estimates -> First resources estimation
Scheduler View -> operation of vhdl components in time

3. C/RTL Cosimulation

Instruments the testbench, generate reference data, starts and run Vivado Simulation. 

You can take a first look into VHDL code, but code is very criptic. 

4. Package

Settings -> IP -> Reporsitory -> Path -> Select and add IP Core to block diagram

5. Implementation 

More accurate resources estimation (only generated IP)

### Algorithm inference

**Scheduling** determine which operation of the DFG will be executed in which clock cycle. This is based on the clock period and the delay time of the operation resources in the target device. In case that an operation needs more time than a clock cycle, multi-cycle resources might be used. Scheduling can be influenced by the user with directives. 

**Binding and Control Logic Extraction**: during the binding phase the operation schedules clock phases wil be bound to the target FPGA resources. A re-use of resources for operations is possible, if operation do not occur in the same clock cycle. Finally an FSM is extracted wich always controls the data paht (the FSM is not present if the IP runs in 1 clk). 

**Directives**

syn.op=mult impl=dsp -> Implement the multiplication operation using DSP.

Arrays in C will be implemented as BRAM interfaces.
The FSM control he execution of the IP Core over the clock cycles. It generates the control signals needed. 

**Limitations**

* Not portable code. You have to go to de first step of HLS and change the target. 
* Not every porgram may be suotable for HLS.
* System calls are not supported (printf)
* Dynamic memory is not suprotesd
* Some limitations on pointer usage (function pointers are not supported)
* Reursive functions

## Data types

* Standard C/C++ Data types: infers data widths based on C widths. If you use floats it will generates floating point code, not optimal.
* Arbitrary Precision Data types: ap_uint<N> (unsigned), ap_int<N> (signed). N number of bits. 

## Interface: Ports and protocols.

Block-level protocol: 
* Control the operation of the IP core. 
* Signals are active high.
* ap_clk: Clock rising edge (Default)
* ap_rst: Reset ative high and syncrhonus (Default)
* hs_protocol (handshake protocol) -> ap_ctrl:
	* ap_start: starts the operation of the IP Core. Must be active high for at least one clock cycle.
	* ap_ready: if active high new data can be applied to the input
	* ap_done: if active, this shows thtat the output is valid
	* ap_return: return value of a function 
	* ap_idle: if active shows that the IP Core is idle, not operating. 
* ap_memory (memory protocol):
	* ap_data_addres
	* ap_data_ce
	* ap_data_q0
	
C arguments types:
* Scalar Arguments: input port, keep the input during all the IP performance. 
* Pointer and references: 
	* if onlt read: like scalar value -> input port will be generated
	* if only written: output port and hs_protocol
	* read/write: purely combinational
* Arrays: 
	* External BRAM should be attached to the IP Core
	* Protocol: ap_memory
	

AXI Interface:
* AXI4-Lite
* Clk
* Reset
