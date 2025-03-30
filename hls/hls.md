# High Level Synthesis

### PART 1

### PART 2

Not portable code. You have to go to de first step of HLS and change the target. 

**Directives**

syn.op=mult impl=dsp -> Implement the multiplication operation using DSP.

Arrays in C will be implemented as BRAM interfaces.
The FSM control he execution of the IP Core over the clock cycles. It generates the control signals needed. 


**Limitations**

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