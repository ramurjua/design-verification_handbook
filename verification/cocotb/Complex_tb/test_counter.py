import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import random

# Driver
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

# Monitor
class CounterMonitor:

  def __init__(self, dut, callback):
    self.dut = dut
    self.callback = callback

  async def observe(self):
    while True:
      await RisingEdge(self.dut.clk)
      self.callback(int(self.dut.o_tc.value))

# Scoreboard
class CounterScoreboard:

  def __init__(self):
    self.expected = []
    self.actual = []

  def add_expected(self, value):

    self.expected.append(value)

  def compare(self, value):
    self.actual.append(value)
    assert self.actual == self.expected, f"Mismatch! Expected {self.expected}, got {self.actual}"

# Setup
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

# Test case
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

# Main test
@cocotb.test()
async def test_counter(dut):
  
  driver, scoreboard = await setup_testbench(dut)
  
  # Generate N random test values within the valid range
  bit_width = len(dut.ip_module)
  max_val = 2**bit_width - 1
  num_tests = 5 # or however many tests you want

  random_values = [random.randint(1, max_val) for _ in range(num_tests)]

  for ip_module_val in random_values:
    await run_counter_test(dut, driver, scoreboard, ip_module_val)
