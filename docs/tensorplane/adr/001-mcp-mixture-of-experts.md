# ADR 001: MCP-Governed Mixture of Experts for Safe Bare-Metal Operations

- Status: Accepted
- Date: 2026-03-24
- Deciders: Tensorplane Principal Architecture Group
- Supersedes: None
- Related: [Agent Architecture](../AGENT_ARCHITECTURE.md), [Vision](../VISION.md)

## Context

Tensorplane previously allowed a single, general-purpose "do-it-all" coding agent to reason, generate code, and execute host-level operations with insufficient separation of duties.

That operating model failed catastrophically: the agent executed a script that unbound the NVMe root drive on the host OS, causing a host crash and service interruption.

This incident demonstrated that prompt-level instruction quality is not an adequate control boundary for bare-metal or privileged execution. The platform requires architectural controls that are enforceable at runtime, auditable, and resilient to agent reasoning errors.

## Decision

Tensorplane mandates a Magentic-One-style Multi-Agent System (MAS) with a Mixture of Experts (MoE), governed by the Model Context Protocol (MCP) as a strict security boundary.

### Mandatory Architecture

1. Central Orchestrator only:
- A single Orchestrator owns global planning, delegation, and checkpointing.
- Specialist agents are task executors, not autonomous planners.

2. Mixture of Experts only:
- CloudOps/WebSurfer agent: read-focused infrastructure and web context gathering.
- Coder agent: restricted to C++/Rust dataplane code and deployment script authoring/analysis.
- ComputerTerminal/Executor agent: restricted to isolated shell/runtime execution.

3. MCP as hard boundary:
- All tool access is mediated through MCP servers/gateways.
- No direct, implicit API trust or unrestricted terminal access to any agent.
- Tool permissions are explicit, role-scoped, and policy-enforced.

4. Separation of duties is non-optional:
- Code generation and runtime execution must be separated across different specialist roles.
- High-impact operations (storage attach/detach, block-device binding/unbinding, mount operations, privileged scripting) require explicit policy gates and approval flow.

5. Ledgered orchestration required:
- Outer Loop Task Ledger for facts, assumptions, risks, and plan state.
- Inner Loop Progress Ledger for step outcomes, reflection summaries, retries, and stall detection.

6. Reflection before context promotion:
- Raw terminal output and compiler logs are not promoted directly into global context.
- Executor agents must summarize state deltas and error classes before Orchestrator ingestion.

## Rationale

This decision converts safety from a best-effort prompt convention into a system property:
- Least-privilege capability design limits blast radius.
- Role isolation prevents a single agent from chaining unsafe actions across planning, coding, and execution.
- MCP policy enforcement and auditability provide deterministic governance and forensic traceability.
- Ledgered control loops reduce drift and detect execution stalls/failure loops before escalation.

## Consequences

### Positive

- Significant reduction in catastrophic host-level failure risk.
- Improved traceability for incident response and compliance.
- Higher execution reliability for long-running infrastructure tasks.
- Better context efficiency through reflection-based summarization.

### Trade-offs

- Additional orchestration complexity and implementation overhead.
- Slightly higher latency per task due to policy checks and role handoffs.
- Need to maintain explicit tool permission maps and approval rules.

## Non-Compliance Policy

Any workflow that grants a single agent both unrestricted code-authoring and unrestricted host execution authority is non-compliant with this ADR and must not be deployed.

## Implementation Notes

- Enforce per-agent MCP allowlists with explicit read/write/execute segregation.
- Introduce hard deny rules for destructive storage actions unless approval tokens are present.
- Require structured reflection payloads in Executor responses.
- Persist Task/Progress ledgers as first-class orchestration artifacts.

## Review Cadence

This ADR must be reviewed quarterly or immediately after any high-severity incident involving privileged execution paths.
