# Language of the HDL files
TOPLEVEL_LANG = verilog

# Verilog source files
VERILOG_SOURCES = counter.v

# Top-level module name
TOPLEVEL = counter

# Python test module (without .py)
MODULE = test_counter

# Simulator to use (icarus, verilator, modelsim, etc.)
SIM = icarus

# Default parameter value if not provided
PW_COUNTER_MODULE ?= 5

# Pass the parameter to the simulator
EXTRA_ARGS += -pvalue+pw_counter_module=$(PW_COUNTER_MODULE)

# Include cocotb's simulation makefile
include $(shell cocotb-config --makefiles)/Makefile.sim
