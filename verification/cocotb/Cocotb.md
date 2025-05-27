# Cocotb

Cocotb is a powerful verification framework that allows you to write testbenches for digital hardware using Python instead of traditional HDL languages like Verilog or VHDL. It simplifies the testing process by leveraging Python's readability, extensive libraries, and advanced features such as coroutines and randomization. This makes it easier to write, debug, and scale complex test scenarios. Cocotb also integrates seamlessly with existing simulators, enabling modern software practices like unit testing and continuous integration in hardware development workflows.

## Create a simple testbench

The following steps will describe how to verify a simple 4 bits adder, the files needed are in the example folder. As any other python package, the installation can be done using pip: pip3 install cocotb

1. Import needed libraries:

* import cocotb: imports the cocotb library, which gives access to the simulation environment and decorators.
* from cocotb.triggers import Timer: Timer trigger pauses the test for a certain amount of simulation time.
* import random: module to generate random input values for testing.

```python
import cocotb
from cocotb.triggers import Timer
import random
```

2. Create a test case:

* @cocotb.test(): this is a decorator that tells cocotb to treat the function below it as a test case.
* async def adder_basic_test(dut): this defines the actual test function. async is used because cocotb testbenches are coroutine-based (non-blocking)
* dut is a handle for the top-level Verilog module

```python
@cocotb.test()
async def adder_basic_test(dut):
```

3. Generate stimuli just in python:

```python
for _ in range(10):
    a = random.randint(0, 15)
    b = random.randint(0, 15)
```

4. Link stimuli with DUT, .value is used to assign or read signal values in cocotb.

```python
dut.a.value = a
dut.b.value = b
```

5. Set some delays, wait 2 nanoseconds of simulation time.

```python
await Timer(2, units='ns')
```

6. Compute the expected result and assert it:

In Python, assert is used to check that a condition is True. If it's not, it will raise an AssertionError and optionally print a meesage. 

Syntax:

```python
assert <condition>, <error_message>
```
In this example:

```python
expected = a + b
assert dut.sum.value == expected, f"Test failed: {a} + {b} != {dut.sum.value}"
```

## Setup the simulation enviroment

The Makefile is a key part of running cocotb simulations — it's how cocotb knows what files to simulate, what simulator to use, and what Python test to run.

A Makefile is a plain text file used by the make tool to automate commands. It's like a script that tells cocotb:
* Language of the HDL files: TOPLEVEL_LANG
* Source files: VERILOG_SOURCES
* Top level module: TOPLEVEL
* Testbench file: MODULE
* Simulator to use: SIM

## Launch test

From a gitBash terminal run:

```bash
make
```
If make is not installed, you can download it here https://sourceforge.net/projects/ezwinports/. Aftewards it should be added to the system path.

If the test passed successfully the terminal should print:

```bash
** TEST                          STATUS  SIM TIME (ns)  REAL TIME (s)  RATIO (ns/s) **
**************************************************************************************
** test_adder.adder_basic_test   ←[32m PASS ←[49m←[39m         20.00           0.00      10011.97  **
**************************************************************************************
** TESTS=1 PASS=1 FAIL=0 SKIP=0                 20.00           0.33         59.90  **
**************************************************************************************
```