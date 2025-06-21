import cocotb
from cocotb.triggers import Timer
import random

@cocotb.test()
async def adder_basic_test(dut):
    """Basic test for the 4-bit adder"""
    for _ in range(10):
        a = random.randint(0, 15)
        b = random.randint(0, 15)
        dut.a.value = a
        dut.b.value = b

        await Timer(2, units='ns')

        expected = a + b
        assert dut.sum.value == expected, f"Test failed: {a} + {b} != {dut.sum.value}"