## Using advanced verification components: counter example

The following steps will describe how to verify a parametrized up-counter, the files needed are in this folder.

1. Define the Driver:

The driver is responsible for applying inputs to the DUT:

- init: constructor function, it passes the dut
- reset: applies a reset pulse
- send: sets the ip_module input value

```python
class CounterDriver:
  
  def __init__(self, dut):
    self.dut = dut

  async def reset(self):
    self.dut.rst.value = 1
    await RisingEdge(self.dut.clk)
    self.dut.rst.value = 0
    await RisingEdge(self.dut.clk)

  async def send(self, ip_module_val):
    self.dut.ip_module.value = ip_module_val
```

Notice that the parameter pw_counter_module is a Verilog parameter, which means it must be set before the simulation is compiled and run. This is done via the Makefile or the simulator command line.

| Task                  |	Where It Happens | How                               |
|-----------------------|------------------|-----------------------------------|
| Set pw_counter_module	| Makefile / CLI	 | make PW_COUNTER_MODULE=6          |
| Use pw_counter_module	| Verilog	         | parameter pw_counter_module = ... |
| React to it in test	  | Python	         | len(dut.ip_module)                |

2. Define the Monitor:

The monitor observes DUT outputs and passes them to scoreboard:

- init: constructor function, callback preguntar?
- observe: continuosly watches *o_tc* and calls the callback with its value. A callback is simply a function that is passed as an argument to another function or object, with the intention that it will be called later — usually when a specific event occurs.

```python
class CounterMonitor:

  def __init__(self, dut, callback):
    self.dut = dut
    self.callback = callback

  async def observe(self):
    while True:
      await RisingEdge(self.dut.clk)
      self.callback(int(self.dut.o_tc.value))
```

3. Define the scoreboard:

The scoreboard compares expected and actual outputs:

- add_expected: adds expected output value
- compare: compares actual output with expected and raises an error if the differ

```python
class CounterScoreboard:

  def __init__(self):
    self.expected = []
    self.actual = []

  def add_expected(self, value):

    self.expected.append(value)

  def compare(self, value):
    self.actual.append(value)
    assert self.actual == self.expected, f"Mismatch! Expected {self.expected}, got {self.actual}"
```

4. Test flow:

  * Start the clock: a 10 ns clock is created and started using cocotb.clock.Clock.
  * Initialize the driver, monitor, and scoreboard: these components are instantiated to handle stimulus, observation, and checking.
  * Connect the monitor to the scoreboard: a callback function is defined to send observed values to the scoreboard.
  * Reset the DUT: the reset() method is called to initialize the DUT into a known state.
  * Start monitoring the DUT output: the monitor begins observing o_tc on every rising clock edge.
  * Determine the bit width of ip_module dynamically: the test reads the width of the ip_module input using len(dut.ip_module).
  * Generate a valid random value for ip_module: a random integer between 1 and the maximum value allowed by the bit width is selected.
  * Log the test configuration: the test logs the current parameter width and test value for traceability.
  * Verify the test value fits the input width: an assertion ensures the generated value does not exceed the allowed range.
  * Send the value to the DUT: the driver applies the ip_module value to the DUT.
  * Expect o_tc = 0 for ip_module clock cycles: the scoreboard is loaded with expected zeros for the duration of the count.
  * Expect o_tc = 1 on the next cycle: after the count completes, the scoreboard expects a terminal count signal.

```python
@cocotb.test()
async def test_counter(dut):

  clock = Clock(dut.clk, 10, units="ns")
  cocotb.start_soon(clock.start())

  driver = CounterDriver(dut)
  scoreboard = CounterScoreboard()

  def monitor_callback(value):
    scoreboard.compare(value)

  monitor = CounterMonitor(dut, monitor_callback)

  await driver.reset()
  cocotb.start_soon(monitor.observe())

  bit_width = len(dut.ip_module)
  max_val = 2**bit_width - 1

  ip_module_val = random.randint(1, max_val)

  dut._log.info(f"Testing with pw_counter_module={bit_width}, ip_module={ip_module_val}")

  assert ip_module_val <= max_val, f"ip_module value {ip_module_val} exceeds {bit_width} bits"

  await driver.send(ip_module_val)
  
  for _ in range(ip_module_val):
    scoreboard.add_expected(0)
    await Timer(10, units="ns")

  scoreboard.add_expected(1)
  await Timer(10, units="ns")
```

5. For modularity and readable purposes, it is suggested to separate the setup and the execution in different functions:

* Setup function, initialize the environment

```python
async def setup_testbench(dut):
  clock = Clock(dut.clk, 10, units="ns")
  cocotb.start_soon(clock.start())

  driver = CounterDriver(dut)
  scoreboard = CounterScoreboard()

  def monitor_callback(value):
      scoreboard.compare(value)

  monitor = CounterMonitor(dut, monitor_callback)

  await driver.reset()
  cocotb.start_soon(monitor.observe())

  return driver, scoreboard
```
* Execution, the test case

```python
async def run_counter_test(dut, driver, scoreboard, ip_module_val):
  bit_width = len(dut.ip_module)
  max_val = 2**bit_width - 1

  assert ip_module_val <= max_val, f"ip_module value {ip_module_val} exceeds {bit_width} bits"
  dut._log.info(f"Testing with pw_counter_module={bit_width}, ip_module={ip_module_val}")

  await driver.send(ip_module_val)

  for _ in range(ip_module_val):
      scoreboard.add_expected(0)
      await Timer(10, units="ns")

  scoreboard.add_expected(1)
  await Timer(10, units="ns")
```

* Main test, calls setup and run multiple cases

```python
@cocotb.test()
async def test_counter(dut):
  driver, scoreboard = await setup_testbench(dut)

  # Run multiple test cases with different ip_module values
  for ip_module_val in [1, 3, 5, 7]:
      await run_counter_test(dut, driver, scoreboard, ip_module_val)
```

6. Run the test providing the PW_COUNTER_MODULE value:

```bash
make PW_COUNTER_MODULE=6
```
