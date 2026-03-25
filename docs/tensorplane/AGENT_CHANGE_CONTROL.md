# Agent Customization Change Control

This document defines the required update and review flow for agent customization artifacts before they are merged into the main repository branch.

## Scope

The policy applies to all customization artifacts that affect autonomous behavior, tool access, or execution safety:

- `.github/agents/*.agent.md`
- `.github/prompts/*.prompt.md`
- `.github/instructions/*.instructions.md`
- `.github/hooks/*.json`
- `copilot-instructions.md`
- `AGENTS.md`

## Governance Objectives

- Preserve least-privilege boundaries and role isolation.
- Require human review for behavior-changing updates.
- Keep all changes auditable and reversible.
- Prevent direct-to-main updates for high-impact agent behavior.

## Required Promotion Flow

1. Draft in a non-production location (for example, private customization repo or feature branch).
2. Open a pull request into `main` in this repository.
3. Include a change summary with:
   - What behavior changed
   - Why the change is needed
   - Risk level (Low/Medium/High)
   - Rollback plan
4. Pass all required checks (see Verification Gate below).
5. Obtain reviewer approvals (see Reviewer Gate below).
6. Merge only after all gates are green.

## Private-to-Local Sync Workflow

To keep private agent definitions available in local development without committing them to this public repository:

1. Store private agent files in a private repository path such as `personal/agents/*.agent.md`.
2. Sync into local workspace using `bash scripts/agents/sync-private-agents.sh`.
3. Prevent accidental public tracking by adding those files to local excludes (`.git/info/exclude`).
4. Promote to public `main` only through the PR-based flow defined above.

## Branching Rules

- Direct commits to `main` are not allowed for scoped files in this policy.
- Use a branch name prefixed with `agent/`, `prompt/`, `instruction/`, or `hook/`.
- Keep PRs small and scoped to one behavior change area when possible.

## Reviewer Gate

Minimum approval requirements:

- 1 reviewer for Low risk changes.
- 2 reviewers for Medium or High risk changes.
- At least one reviewer must be responsible for platform safety/governance.

High risk examples:

- Expanded tool permissions
- New execution-capable hooks
- Changes that affect write/execute boundaries
- Prompt or instruction updates that bypass existing safety constraints

## Verification Gate

Each PR must include evidence for all applicable checks:

- YAML/frontmatter syntax validity for agent/prompt/instruction files.
- Path and schema checks for hook JSON.
- Tool permission diff review for agent definitions.
- Safety impact assessment against:
  - `docs/tensorplane/AGENT_ARCHITECTURE.md`
  - `docs/tensorplane/adr/001-mcp-mixture-of-experts.md`

Recommended CI checks:

- `customization-lint`: frontmatter + schema validation.
- `customization-policy-check`: fail on unsafe permission expansion without required approvals.
- `customization-diff-report`: human-readable summary of behavior and tool-scope deltas.

## Change Request Template

Every PR in scope should include:

- **Behavior change:**
- **User impact:**
- **Security impact:**
- **Tool-scope delta:**
- **Validation performed:**
- **Rollback steps:**

## Rollback Procedure

If a merged customization introduces unsafe or incorrect behavior:

1. Revert the merge commit immediately.
2. Disable associated prompt/agent entry points if needed.
3. Open an incident note linked to the revert commit.
4. Re-introduce the change only through a new PR with corrected controls.

## Audit and Review Cadence

- Review this policy quarterly.
- Trigger immediate policy review after any high-severity incident involving autonomous execution or privilege misuse.

## Relationship to Existing Architecture Policy

This change-control policy operationalizes the governance principles already defined in:

- `docs/tensorplane/AGENT_ARCHITECTURE.md`
- `docs/tensorplane/adr/001-mcp-mixture-of-experts.md`
