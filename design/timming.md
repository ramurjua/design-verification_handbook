# Timming Analysis

In digital designs each and every flip-flop has some restrictions related to the data with respect to the clock. There is always a region around the clock edge in which input data should not change at the input. If the data changes within this window, we cannot guarantee the output. The output can be the result of either of the previous input, the new input or metastability. This window is marked by the setup time and the hold time. 

* Setup time: is defined as the minimum amount of time required to for the input to a FF to be stable before a clock edge. 
* Hold time: is defined as the minimum amount of time required for the input to a FF to be stable after a clock edge. 

Mitigating setup violation:
1. Decreasing clk->q delay of launching flop 
2. Decreasing the propagation delay of the combinational cloud 
3. Reducing the setup time requirement of capturing flop 
4. Increasing the skew between capture and launch clocks
5. Increasing the clock period

Mitigating hold violation: We can meet the hold requirement by:
1. Increasing the clk->q delay of launching flop
2. Decreasing the hold requirement of capturing flop
3. Decreasing clock skew between capturing clock and launching flip-flops

### How does setup and hold time relate to clock frequency?

The maximum clock frequency is the mimum clock period (T), and the minimum period allowed for a circuit is equal to the addition of setup time (tsu), propagation time (tp) and hold time (th). The propagation delay is the amount of time it takes for signals to pass between two Flip-Flops.

fmax = 1.0 / (tsu + tp + th)

### What is metastability?

Metastability is a phenomenon of unstable equilibrium in digital electronics in which the sequential element is not able to resolve the state of the input signal; hence, the output goes into unresolved state for an unbounded interval of time. 

The flop starts to capture the data and output also starts to transition. But, before output has changed its state, the input is cut-off from the output as clock edge has arrived. The output is, then, left hanging between state ‘0’ and state ‘1’. Theoretically, the output may remain in this state for an indefinite period of time. But, given the time to settle down, the output will eventually settle to either its previous state or the new state. Thus, the effect of signal present at input of flop may not travel to the output of the flop partly or completely. The metastability failure is said to have occurred if the output has not resolved itself by the time it must be available for use.

## Synchronizers

Asynchronous signals cause catastrophic metastability failures when introduced into a clock domain. So, the first thing that arises is to find ways to avoid metastability failures. But the fact is that metastability cannot be avoided. A synchronizer is a digital circuit that converts an asynchronous signal from a different clock domain into the recipient clock domain so that it can be captured without introducing any metastability failure. However, the introduction of synchronizers does not totally guarantee prevention of metastability. It only reduces the chances of metastability by a huge factor. Thus, a good synchronizer must be reliable with high MTBF, should have low latency from source to destination domain and should have low area/power impact.

* Two flip-flop synchronizer
* Handshacking based synchronizer
* Mux based synchronizer
* Two clock FIFO synchronizer

### Two flip-flop synchronizer

This is the most simple and most common synchronization scheme and consists of two or more flip-flops in chain working on the destination clock domain. This approach allows for an entire clock period for the first flop to resolve metastability.

The two flop synchronizer must be used to synchronize a single bit data only. Using multiple two flops synchronizers to synchronize multi-bit data may lead to catastrophic results as some bits might pass through in first cycle; others in second cycle. Thus, the destination domain FSM may go in some undesired state.

MTBF decreases almost linearly with the number of synchronizers in the system. Thus, if your system uses 1000 synchronizers, each of these must be designed with at least 1000 times more MTBF than the actual reliability target.

### Handshacking based synchronizer

Two flop synchronizer works only when there is one bit of data transfer between the two clock domains and the result of using multiple two-flop synchronizers to synchronize multi-bit data is catastrophic. 

The solution for this is to implement handshaking based synchronization where the transfer of data is controlled by handshaking protocol where in source domain places data on the REQ signal. When it goes high, receiver knows data is stable on bus and it is safe to sample the data. After sampling, the receiver asserts ACK signal. This signal is synchronized to the source domain and informs the sender that data has been sampled successfully and it may send a new data. 

Handshaking based synchronizers offer a good reliable communication but reduce data transmission bandwidth as it takes many cycles to exchange handshaking signals. Handshaking allows digital circuits to effectively communicate with each other when response time of one or both circuits is unpredictable.

### Mux based synchronizer

It is suitable for more than 1-bit widht. The working is that the source domain sends an enable signal indicating that it the data has been changed. This enable is synchronized to the destination domain using the two flop synchronizer. This synchronized signal acts as an enable signal indicating that the data on data bus from source is stable and destination domain may latch the data. The two flop synchronizer acts as a sub-unit of mux based synchronization scheme.

### Two clock FIFO synchronizer

It is a 'cyclic buffer' (dual port RAM) that is written into by the data coming from the source domain and read by the destination domain.

There are two pointers maintained; one corresponding to write, other pointing to read. These pointers are used by these two domains to conclude whether the FIFO is empty or full. For doing this, the two pointers (from different clock domains) must be compared. Thus, write pointer has to be synchronized to receive clock and vice-versa. Thus, it is not data, but pointers that are synchronized.