# Basic Concepts

## Introduction

The ASIC (Application-Specific Integrated Circuit) Design Flow consists of several steps including: design specification, design entry, design synthesis, design verification, physical design and design sing-off. Design Verification typically referens to pre-silicon effort of fcuntional validation of design using simulation tools. 

Digital design verification is the process of testing and validating the correctness and functionality of a digital design before it is released or depliyed. The goal is to identify and eliminate any design errors or bugs, and to ensure thtat syustem performs as expected under different conditions and use cases. 

**Importance of design verification**

* Increasing design complexity: As the complexity of the design increases, the number of possible scenarios that need to be verified also increases. 
* Iterative process: Design verification is an iterative process that involves running simulations, analyzing results, and fixing design errors. This process may need to be repeated multiple times until the design meets all the required specifications and performs as expected. 
* Development of verification environment: The verification environment must be comprehensive and cover all possible scenarios, which can be a time-consuming task.
* Time-sensitive nature of design verification: Design verification is a time-sensitive task because it must be completed before the design is fabricated.

**What happen if a bug is missed?**

* Rework and delay
* Lost revenue
* Product recalls
* Legal liabilities

**When is time to stop verification?**

* Achieving code coverage goals: all code coverage goals like branch, statement, expression, toggle and FSM have been met.
* Achieving functional coverage goals: functional coverage is at an acceptable level.
* Meeting performance goals: design meets all performance goals, such as timing constraints and power consumption requirements.
* Finding and fixing critical bugs: no new critical bugs have been introduced for a certain period
* Available reosurces: verification can be stopped if the available resources are not sufficient to continue, such as budget or time constraints.

## Verification Techniques

* **Functional Simulation**: it involves running the digital design on a computer or a simulator to validate its functionality. The simulation environment may include various inputs, such as test vectors to ensure design behaves as expected. *Example: testing an ALU.*
* **Formal Verification**: involves using mathematical proofs to verify the correctness of the design. This technique is often used for critical designs, such as those used in safety-critical systems. *Example: testing that a FIFO never overflows.*
* **Emulation**: it involves testing the digital design on specializrd hardware that can emulate the behaviour of the system. This technique is often used for large, complex designs that cannot be simulated on a computer. *Example: executing in Linux a Risc-V processor before manufacturing the chip.*
* **Prototyping**: involves building a physical prototype of the system to test its functionality in a real-world enviroment. This technique is often used for designs that require testing with real-world inputs and conditions. *Example: test an PCIe interface using an FPGA before manufacturing the chip.*

Return 📂 home: [Main Readme](../README.md) 