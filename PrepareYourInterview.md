## Talk about yourself

**Tell me about you**

Hello again my name is Raquel, as you know. I am electronics engineer with a master's degrees in electronics systems specialized in digital electronics. I started in an university team Hyperloop UPV doing hardware and I went moving more into control algorithms and microcontrollers programing. It was on the master, when I found what I trully love. It was hardware description languages, I like coding and I also like hardware so for me code that directly translates into circuits is amazing. That's how I started with FPGAs and what I am working on right now. I work in a company named Power Electronics which is into power converters control and renawable energies. 

**Why Apple?**

I have been always a fan of Apple, I have had iPhones and an iPad. But what I truly admire about apple is the hability to **create elegant solutions for really hard problems**. 

Apple stands for the **excellent both in hardware and software**. And the position that I am appliying is related to verification which is has direct impact into it. 

I want to be part of Apple to **make real solutions** that have an impact on people, **learn from the best professionals** in the sector within the **edge technologies**.

**Prepare to explain what you do day-to-day in your latest role**

Key points:

* What do you do in your day to day
* How it relates to the requirements laid out in the job description
* How your skills and experience make you qualified and competitive candidate

*Explicar las fases de la espec: pensamiento, diseño, verificacion, pruebas en HIL*

My daily routine varies depending on the stage of the project—whether it's design, verification, or hands-on testing. Each design iteration is divided into specifications, and I take ownership of the all process of the specification assined to me. Since designing the architecture that suits better the goal, to make the RTL design and finally to verify it. 

On the design stage firstly I have to think what is the best solution to accomplish the specification goal. Once I have good proposal, I document it and present it to the team for review and improvement. An example could be selecting the best protocol communication to ensure that timing requirements are met. After finalizing the approach, I move to implementation, writing RTL code in Verilog.

Once the design is complete, I shift focus to verification. I develop functional tests by comparing the RTL design against a golden model, usually written in Python. Both models receive identical stimuli, and I analyze the responses to determine whether the test passes or fails. My test cases cover both typical scenarios and corner cases, ensuring robustness. Since I work in power converters control application I frequently work with algorithms such as filters and PI regulators. A key challenge in verification is fixed-point arithmetic, for ensuring numerical stability and precision across all possible inputs.

When the verifying stage has cover the sufficient number of cases to consider the module works at expected I add the new testbench to the project pipeline and the hands-on testing starts. My code ends in an FPGA, so I load the bitstream or memory configuration file into it and I do HIL based-testing. Meaning we have a computer that is like a virtual twin of the power converter itself so testing in real hardware doesn't involves hazards in people or in other machines. It works with Simulink and there I can test the complete system integration easily, using internal logic analyzers, virtual input outputs, oscilloscopes and some laboratory material in order to ensure the system correctness. 

**Discuss specific examples from your work experience**

* Important projects
* Challenges you've learned from

*XMV: bug en el modulador cuando hay fallo de comunicaciones con el DSP*

One of the biggest challenges in my career happened when I was asked to debug a multilevel converter design—an old project inherited from when the company first started. A critical bug had been reported from the field: the power hardware was suddenly exploding. The team had already ruled out hardware issues, so the problem had to be in the FPGA since it is the device that controls the transitors.

At first, I thought, "Okay, let’s check the documentation and testbenches." But there was nothing—no documentation, no verification environment, nothing. That’s when I realized this was going to be much more complicated than just fixing a bug.

I have no words to explain how it was the first dive into the code. Signals were driven inside unrelated modules without being passed as proper ports, signal names no longer reflected their actual functions, and different parts of the design had been modified over the years without any clear structure. The first thing I had to do was untangle everything—making each module independent so I could even begin to understand what was going on.

Once I managed to clean up the design enough to start testing, I wrote some basic testbenches to check the usual scenarios. Everything seemed fine at first, at the end it was a conveter that have been working for around ten years. Then I started running more extreme cases, and that’s when I found it: the problem was inside the modulator module, the block responsible for switching the transistors.

The way it was designed, the carrier was generated by the FPGA but the modulator values came from a DSP, another device in the electronics. If, for any reason, the DSP sent a bad message or failed to send anything, the modulation values would just freeze. That meant the transistors could get stuck conducting high current for too long, leading to excessive power dissipation… and ultimately, an explosion.

Once I understood the issue, I developed a predictor mechanism. Instead of leaving the transistors in a dangerous state when DSP communication failed, the FPGA would automatically generate a decreasing amplitude modulation signal with the same frequency, saftely shutting down the inverter instead of causing a catastrophic failure.

This project taught me a lot—first and foremost, the critical importance of verification. It also made me much better at working with undocumented, unverified designs. After going through all that trouble, I didn’t want future engineers to have the same experience, so I created a Python script to automatically generate documentation from Verilog files. Now, as long as engineers add comments to their code, the documentation updates itself in the repository’s README file.

Looking back, it was one of the most challenging but rewarding projects I’ve worked on. It pushed my debugging skills to the limit, forced me to think creatively under pressure, and ultimately helped make the design safer and more reliable.

**Do you use UVM for verification?**

*Explicar nuestro entorno de verificacion: custom SystemVerilog functions, no UVM por tiempos del simulador*

Although my team doesn’t strictly follow UVM, we’ve developed reusable SystemVerilog functions to streamline verification as well a tcl and Python scripts to automatize tasks. For instance, instead of a UVM scoreboard, we have a function that takes a file with expected values and compares it to the design's outputs, checking for errors within a specified tolerance.

The main reasons we don’t use UVM is that most of our designs involve control algorithms for power converters, where simulation time is a major concern. Since grid frequencies are around 50–60 Hz, running simulations for realistic time frames can be quite slow. To optimize performance, we use Icarus Verilog for pipeline verification, which unfortunately doesn’t support UVM.

**How do you analyze the test coverage?**

When I verify a design, I always ensure that the test coverage is high enough to give confidence in the implementation. Let me give you an example of how I analyze test coverage in a real scenario.

I was once verifying a PI (Proportional-Integral) controller implemented in an FPGA. Since this was a control algorithm, traditional code coverage tools like toggle or branch coverage weren’t enough—I needed to ensure that the functional behavior was well tested.

The first step was to indetify the functional coverage goals, so I started by listing the key scenarios that the PI controller had to handle. For example: step response, adaptability of Kp and Ki parameters, saturation, noisy inputs, incorrect references... 

After running initial tests, I noticed that some important cases had not been covered, so I added them to the test plan. To keep track of coverage, my SystemVerilog testbench includes a function that prints a report summarizing tested conditions. Additionally, the Python script orchestrating the simulation logs both the expected test scenarios and the actual ones executed, along with their results.

This approach helps me systematically track coverage and ensure that all critical functional cases are verified, ultimately improving the confidence in the design’s robustness.

**What areas do you think you need to develop further?**

One area I want to develop further is my proficiency with UVM-based verification methodologies. While my team has primarily used custom SystemVerilog functions, I recognize the advantages of a structured verification environment like UVM, especially for large-scale projects.

To bridge this gap, I’ve been studying UVM concepts, exploring testbench architectures, and practicing with small test cases in my own time. I’m confident that my strong verification background will allow me to adapt quickly if required.

Additionally, I’d like to enhance my scripting skills in Python and TCL to further automate verification workflows and improve efficiency in debugging and simulation setups.
