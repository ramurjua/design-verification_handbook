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

## Verification Methodologies

* **UVM (Universal Verification Methodology)**:
    * UVM is a widely-used, standardized verification methodology built on SystemVerilog. It provides a robust framework for functional verification, offering reusable components for stimulus generation, checking, and reporting.
    * Key aspects:
        * Testbenches: The environment where your design gets tested.
        * Transactions: Defined data packets that are sent across interfaces.
        * Sequences: A series of transactions or commands that are run during verification.
* **Coverage-Driven Verification (CDV)**:
    * This approach focuses on ensuring that all parts of the design are tested through a combination of code coverage and functional coverage.
    * It ensures that all the design's possible scenarios (including corner cases) are covered during simulation.
    * *Example:* Using functional coverage to verify that all possible states in a finite state machine (FSM) are visited during the simulation.

## Key Terms

* **Code Coverage**: code coverage tools monitor and report on which parts of the code were exercised during simulation. Achieving high code coverage is important to ensure all paths and conditions in the design are tested.
    * Types of code coverage:
        * Statement Coverage: Ensures that every line of code has been executed.
        * Branch Coverage: Ensures every decision point (like if statements) has been both true and false.
        * Toggle Coverage: Ensures that every flip-flop has been toggled (set/reset).
* **Functional Coverage**: functional coverage tracks how well the design’s functionality has been verified. It involves defining coverage points that represent important design states or events. *Example:* Ensuring all address ranges of a memory controller are tested by creating specific coverage points for them.
* **Assertions**: are crucial in formal and functional verification. They help to monitor whether specific conditions hold true during the simulation and flag errors when these conditions are violated. *Example:* A covergroup assertion can be used to ensure that every possible value of a signal is observed during testing.

Return 📂 home: [Main Readme](../README.md) 