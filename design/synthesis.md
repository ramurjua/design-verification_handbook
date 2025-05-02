### Synthesis and Implementation 

**What is infer latch means? How can you avoid it?**

Infer latch means creating a feedback loop from the output back to the input due to missing if-else condition or missing ‘default’ in a ‘case’ statement. 

Infer latch indicates that the design might not be implemented as intended and can result in race conditions and timing issues.

How to avoid It:

- Always use all branches in the ‘if’ and ‘case’ statements.
- Use default in the ‘case’ statement.
- Have a proper code review.
- Use lint tools, and logical-equivalence-check tools

**What are leaf cells?**

Leaf cell means cells which are self contained ie cells which don't instantiate any other cells in them or where the hierarchy stops ie there are no more branches in the tree ergo leaf.