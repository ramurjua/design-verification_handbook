# Formal Verification

Formal verification is a method of verifying the correctness of a digital design through mathematical techniques, rather than relying on simulation with test cases. It provides a rigorous approach to ensure that a design adheres to its specifications by proving that the design is free from errors. This technique is especially useful in designs where failure can have severe consequences, such as in safety-critical systems or high-reliability applications.

**Why use Formal Verification?**

* High Confidence in Design: it proves that the design will behave as expected for all possible input conditions. This is particularly valuable in scenarios where exhaustive simulation is impractical due to the sheer number of test cases that would be needed.
* Critical systems: For designs such as aerospace or medical devices, where a bug can lead to catastrophic failures, formal verification ensures that the design meets its functional specifications without the risk of untested corner cases.
* Completeness: Unlike simulation-based approaches, which are limited by the number of test cases run, formal verification can provide complete assurance that a property holds across all possible input conditions.

**How it works?**

Formal verification tools use mathematical models to explore all possible states of a digital design. These tools typically rely on techniques such as model checking and theorem proving to exhaustively verify that a set of properties holds for the design. The properties could range from simple assertions to more complex temporal properties that describe the behavior of the system over time.

The verification tool uses the design description (usually written in HDL) and a set of properties or assertions (often written in SystemVerilog Assertions, SVA) to prove that the design satisfies the requirements. If a violation of any property is found, the tool provides a counterexample that shows the specific sequence of events that led to the failure.

## Formal Verification vs. Assertion-Based Verification

Assertion-based verification is a technique that uses assertions -specifics statements- to check that certain conditions hold during the verification process. Assertions are typicallly used to express propierties or expected behaviours of the design. 

An assertion in this context is a statement that must always hold true in the design. If the assertion is violated (i.e., if the condition it checks is false), the simulator or formal verification tool will raise an error or failure message, helping the engineer identify potential issues in the design.

```verilog
property fifo_not_overflow;
    @(posedge clk)
    disable iff (reset)
    (write_enable && !full) |-> (fifo_count < FIFO_DEPTH);
endproperty

assert property (fifo_not_overflow) else $fatal("FIFO overflow detected!");
```

**How are they related?**

Assertion-based verification is a methodoly used withing noth formal verification and simulation to specify and check the behaviour of the design. It provdies a way to express desired design propierties in a clear, checkeable form that can be verified during either simulation or formal verification. 

In formal verification, assertions serve as the properties that the formal tool checks exhaustively across all possible states of the system to verify that they hold true for every scenario. In simulation-based verification, assertions are used to monitor the design during simulation to check whether the design is behaving as expected for a given set of inputs. 

**Why are they not the same?**

* Scope of check: while formal verification can exhaustively check the design for all possible input combination and corner cases using mathematical proofs guaranteeing that a propierty holds in very scenario, assertion-based verification involves writing individual assertions to check certain propierties and they need to be written for each individual case the designer cares about, meaning they are typically targeted at jey functional behaviours. 

* Method of analysis: formal verification use mathematical methods while assertion-based relies on runtime checks, acting like automated checks embedded in the design. 

* Completeness: formal verification can prove a propierty is true for all possible cases while assertions-based is limited to the propierties that the designer has written assertions for. 