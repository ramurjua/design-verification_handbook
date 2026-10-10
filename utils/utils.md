# Utils

A collection of useful tools, scripts, and small hardware hacks designed to simplify and speed up development workflows in DIY electronics and FPGA-based projects. These utilities are meant to reduce manual overhead and promote reusability across different environments and setups. Whether you're looking to automate FPGA builds or repurpose low-cost microcontrollers for debugging, this section gathers practical solutions that can save you time and effort.

### 🔹 RasberryPi Pico JTAG

[RasberryPi Pico JTAG](JTAG_rp2040/xvc-pico.md) provides a cheap and open source method to program and FPGA is using a Rasberry Pico as a JTAG cable. 

### 🔹 Scripts Vivado Workflow

[Scripts Vivado Workflow](Scripts_Vivado_Workflow/vivado.md) provides TCL + BAT scripts for automation flow for creating, synthesizing, implementing, and generating the bitstream, memory configuration file and debug probes using Xilinx Vivado.

### 🔹 QT Designer GUI

[QT Designer GUI](QT_GUI/qt_designer_gui.md) provides a step by step tutorial to create a simple grpahical user interface using QT Designer and Python.

### 🔹 FPGA Scope

[FPGA Scope](fpga_scope/fpga_scope.md) is a logic analyzer / oscilloscope core that is instantiated inside an FPGA design and controlled from a browser through a USB-UART adapter. It captures up to 8 internal signals around a trigger, or streams them live, with no vendor tool or JTAG needed while debugging.
