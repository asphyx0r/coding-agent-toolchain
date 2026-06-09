# AGENTS.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

## Instruction Scope

- Always follow this `AGENTS.md` for agent behavior.
- Before creating, editing, reviewing, or refactoring code, read and follow
  `CODING_RULES.md` for language-agnostic code quality rules.
- When creating, editing, reviewing, or refactoring code, also read and follow
  `LANGUAGE_RULES.md`, applying only the sections for the target language,
  dialect, or framework of the files being edited.
- Before creating, editing, reviewing, or refactoring project documentation,
  read and follow `DOCUMENTATION_RULES.md`.
- When project documentation contains executable code, commands, configuration,
  or API examples, also apply `CODING_RULES.md` and the relevant
  `LANGUAGE_RULES.md` sections to those examples.
- When creating or updating `README.md`, apply `DOCUMENTATION_RULES.md`
  rigorously.
- If an existing `README.md` contains structural anomalies that conflict with
  `DOCUMENTATION_RULES.md`, warn the user and do not silently normalize
  unrelated content unless requested.
- Before creating any commit, read and follow `COMMIT_RULES.md`.
- Before creating any Git tag, read and follow `RELEASE_RULES.md`.
- `README.md` is human-facing repository documentation, not an agent
  instruction file.

When rules conflict, apply them in this order:

1. Project-specific instructions.
2. Commit and release rules from `COMMIT_RULES.md` and `RELEASE_RULES.md`
   when creating commits or Git tags.
3. Documentation-specific rules from `DOCUMENTATION_RULES.md` when creating,
   editing, reviewing, or refactoring documentation.
4. Language-, dialect-, and framework-specific rules from `LANGUAGE_RULES.md`.
5. General code-quality rules from `CODING_RULES.md`.
6. General behavioral rules from this `AGENTS.md`.

## Observable Instruction Protocol

Before creating, editing, reviewing, refactoring, or otherwise modifying code or
project documentation, creating commits, or creating Git tags, the agent must
read the applicable instruction files, then state an instruction audit before
taking the requested action.

The instruction audit must include:

- The task type.
- The instruction files that apply.
- The instruction files already read for the task.
- Any assumptions that affect scope or verification.
- The planned verification step.

Use the instruction scope above to determine which instruction files apply to
the task. Do not duplicate the scope rules in this protocol.

After completing the task, the agent must include a brief compliance recap:

- Which instruction files were applied.
- What verification was run.
- Any instruction that could not be applied, with the reason.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:

- State relevant assumptions explicitly.
- If uncertainty affects scope, behavior, safety, data, public APIs, or user
  intent, stop and ask for clarification.
- If multiple interpretations have materially different outcomes, present them
  before implementing.
- If an ambiguity is minor and does not block progress, choose the simplest
  reasonable option and state the assumption.
- If a simpler approach exists, say so. Push back when warranted.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No defensive error handling for states ruled out by validated invariants; state the invariant when it affects the
  implementation.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:

- Don't "improve" adjacent code, comments, or formatting unless the requested change directly touches it.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.
- Limit cleanup to code changed for the request or direct consequences of those changes.

When your changes create orphans:

- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:

- "Add validation" -> "Write tests for invalid inputs, then make them pass"
- "Fix the bug" -> "Write a test that reproduces it, then make it pass"
- "Refactor X" -> "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:

```text
1. [Step] -> verify: [check]
2. [Step] -> verify: [check]
3. [Step] -> verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and
clarifying questions come before implementation rather than after mistakes.
