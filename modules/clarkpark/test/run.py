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

VERILOG_SOURCES = SOURCES_DIR + "clarkpark.v"
VERILOG_SOURCES += " " + SOURCES_DIR + "dds.v"
VERILOG_SOURCES += " " + SOURCES_DIR + "clarkpark_inv.v"

TEST_SOURCE = "./clark_park_tb.sv"

TOPLEVEL = "clark_park_tb"

# TEST EXECUTION
################

simulador = "iverilog"

# Delete previous files
if exists("./sim_log"):
  print("Removing last sim_log file")
  os.remove("./sim_log")

process = subprocess.Popen("iverilog -o testbench.vvp -s " + TOPLEVEL + " -g2005-sv -gstd-include -grelative-include " + TEST_SOURCE + " " + VERILOG_SOURCES, shell=True)
print(process.wait())
process = subprocess.Popen("vvp -l sim_log testbench.vvp", shell=True)
print(process.wait())
os.remove("./testbench.vvp")


exit()