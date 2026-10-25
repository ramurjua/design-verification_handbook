import os
import time
import subprocess
import platform
import sys
import shutil
import matplotlib.pyplot as plt
from os.path import exists

SOURCES_DIR = "../source/"
TEST_SOURCES_DIR = ""

VERILOG_SOURCES = SOURCES_DIR + "imu_lsm6dsm.v"
VERILOG_SOURCES += " " + "../../spi/source/spi_master.v"


TEST_SOURCE = "./imu_lsm6dsm_tb.sv"

TOPLEVEL = "imu_lsm6dsm_tb"

# TEST EXECUTION
################

simulador = "iverilog"

# Two runs: the default p_i2c_disable = 0 (log in sim_log) and
# with the CTRL4_C I2C_disable write (log in sim_log_i2c_disable, its
# waveform is the .vcd left behind)
for defines, log in (("", "sim_log"), ("-DI2C_DISABLE", "sim_log_i2c_disable")):
  # Delete previous files
  if exists("./" + log):
    print("Removing last " + log + " file")
    os.remove("./" + log)

  process = subprocess.Popen("iverilog " + defines + " -o testbench.vvp -s " + TOPLEVEL + " -g2005-sv -gstd-include -grelative-include " + TEST_SOURCE + " " + VERILOG_SOURCES, shell=True)
  print(process.wait())
  process = subprocess.Popen("vvp -l " + log + " testbench.vvp", shell=True)
  print(process.wait())
  os.remove("./testbench.vvp")


exit()
