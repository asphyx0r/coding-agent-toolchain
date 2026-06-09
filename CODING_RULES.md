# CODING_RULES.md

## Purpose

This file defines practical coding rules for code generated or modified by an AI coding agent.
It is intended to complement `AGENTS.md`: `AGENTS.md` governs agent behavior, while this file governs code quality.

This document is a compact, operational rule set. It is not exhaustive; combine it with repository-specific
instructions, tests, and conventions.

## Scope

Apply these rules when creating, editing, reviewing, or refactoring code.

These rules are language-agnostic. Adapt naming, formatting, testing, and error-handling details to the conventions of
the target language and repository.

## Core Principle

Produce code that other developers can understand, verify, modify, and safely extend.

Within the requested and touched scope, working code is not enough. After making code work, clean it until its intent,
structure, and behavior are clear.

## Operational Definitions

Use these definitions when applying qualitative words in this file:

- `clear` or `readable` : a reviewer can identify intent from names, structure, tests, and local context without relying
  on hidden assumptions or explanatory comments.
- `small` : a function, class, module, or change has one responsibility or one reason to change; split only when the
  current work exposes separate responsibilities.
- `safe` : the change preserves existing public behavior or is covered by tests, static checks, or an explicit
  verification step.
- `relevant`: the change is necessary for the requested outcome, for cleanup caused by the change, or for verification.
- `when practical` , `when possible` , `where possible` , or `when appropriate` : apply the rule unless it conflicts
  with repository conventions, requested behavior, or a verified technical constraint; state the reason when skipping
  it.
- `clear enough` : the relevant review checklist items have an explicit pass, test result, verification step, or stated
  exception.

## General Rules

- Prefer clarity over cleverness.
- Prefer simple structures over speculative abstractions.
- Keep code readable for the next maintainer, not only for the original author.
- Keep code small, well named, organized, and ordered.
- Make behavior easy to verify with tests.
- Treat structural degradation as a real defect, not as cosmetic debt.
- Improve only code you already need to touch for the requested change, and only when the improvement is safe and
  relevant.
- Do not rewrite unrelated code merely because it could be cleaner.
- Do not optimize for performance before readability unless performance is an explicit, measured requirement.

## AI-Generated Code Rules

- Do not trust generated code just because it compiles or looks plausible.
- Verify generated code with executable tests.
- Prefer precise, formal, testable requirements over vague prompts.
- Add representative test scenarios before relying on generated logic.
- Review generated code as if it were written by an unknown contributor.
- Remove unnecessary comments produced by the model when the code itself can express the intent.
- Reject generated code that hides complexity behind vague names, broad functions, or unclear control flow.
- The human or supervising agent remains responsible for correctness, maintainability, and design integrity.

## Naming Rules

### General Naming

- Use names that reveal intent.
- A name should explain why the element exists, what it represents, and how it is used.
- If a name needs a comment to explain it, improve the name or the surrounding structure.
- Use consistent vocabulary for the same concept across the codebase.
- Use one word per concept; do not alternate between synonyms such as `amount` , `cost` , `price` , and `fee` for the
  same domain idea.
- Avoid names that differ only by small visual or textual variations.
- Avoid misleading type or container names.
- Avoid joke names, slang, cultural references, or clever puns.
- Use solution-domain terms for technical concepts and problem-domain terms for business concepts.
- Add context through classes, functions, modules, namespaces, or data structures instead of adding redundant prefixes
  everywhere.

### Variable Names

- Use short variable names only in very small scopes.
- Use longer, more descriptive names as the scope grows.
- Replace magic numbers and unexplained literals with named constants or domain concepts.
- Avoid single-letter names except for short-lived local variables in obvious loops or conventional contexts.
- Make important names searchable across the codebase.

### Function and Method Names

- Use verbs or verb phrases for functions and methods.
- Name functions after the action they perform or the question they answer.
- Prefer names that make the calling code read naturally.
- Use longer names for narrowly scoped private helpers when that improves precision.
- Use shorter names for broad, common, highly reused public operations when the meaning is established.

### Class and Module Names

- Use nouns or noun phrases for classes, records, data structures, and modules.
- Avoid generic suffixes such as `Manager`, `Processor`, `Data`, or `Info` unless they add real meaning.
- Prefer singular names for classes representing one concept.
- Use plural or collection names only for structures that actually represent collections.

### Avoid Encodings

- Do not encode type, scope, or implementation details into names when the language or tools already provide that
  information.
- Do not prefix interfaces merely to indicate that they are interfaces.
- If implementation naming is needed, make the implementation name more specific rather than polluting the abstraction
  name.

## Comments Rules

- Prefer expressive code over explanatory comments.
- Do not use comments to compensate for confusing code; clean the code instead.
- Keep comments close to the code they explain.
- Delete comments that are false, outdated, redundant, noisy, or misleading.
- Do not leave commented-out code in the codebase.
- Avoid journal comments, attribution comments, decorative separators, and obvious restatements of code.
- Avoid nonlocal comments that describe behavior located elsewhere.
- Use comments only when they add information the code cannot reasonably express.

Acceptable comments include:

- Legal or license notices required by the project.
- Warnings about non-obvious consequences.
- Explanation of intent for unusual decisions.
- Clarifications for external APIs, standards, algorithms, or unavoidable ambiguity.
- Public API documentation when required by the language, tooling, or project convention.
- Temporary TODO comments only when they are specific, actionable, owned, and easy to find later.

## Formatting Rules

- Treat formatting as communication.
- Follow the repository formatter and style rules when they exist.
- Use automated formatting tools whenever available.
- Keep formatting consistent across the team and repository.
- Prefer small files over very large files; when size starts to hide separate
  responsibilities, split only along responsibilities exposed by the current
  work.
- Separate unrelated concepts vertically.
- Keep tightly related lines close together.
- Place related functions near each other when it improves readability.
- Place higher-level functions before lower-level details when using a top-down reading style.
- Keep line length and horizontal spacing readable according to local conventions.
- Use indentation to show structure clearly.
- Do not break indentation conventions for novelty or compactness.

## Function Rules

- Keep functions small.
- Make each function do one thing at one level of abstraction.
- Extract named helper functions when a block of code has a clear purpose that can be named.
- Avoid mixing high-level policy with low-level details in the same function.
- Organize functions so readers can move from high-level intent to implementation details naturally.
- Avoid hidden side effects.
- Avoid output arguments when returning a value is clearer.
- Prefer pure functions when practical, especially for calculations and transformations.
- Keep commands and queries separate when possible: a function should either change state or answer a question, not
  both.
- Do not use flags to make one function perform multiple distinct behaviors.
- Limit argument count. When arguments make call sites hard to understand or
  form one coherent concept, introduce a meaningful object, data structure, or
  parameter object.
- Use keyword or named parameters when the language supports them and they improve clarity.

## Error Handling Rules

- Prefer clear error-handling mechanisms over ambiguous return codes.
- Keep error handling separate from primary business logic when possible.
- Extract complex error-handling blocks into dedicated functions.
- Do not allow error-code dependencies to spread through the codebase.
- Use exceptions, result types, or language-appropriate mechanisms consistently with project conventions.
- Write tests for failure paths, not only happy paths.

## Duplication Rules

- Remove accidental duplication.
- Do not duplicate business rules across modules.
- If similar code changes together for the same reason, consider extracting the shared concept.
- Do not force abstraction over code that only appears similar but represents different domain concepts.
- Prefer explicit duplication over a premature abstraction when the abstraction is not yet clear.
- When cleaning duplication, keep tests passing after each small step.

## Object and Data Structure Rules

- Keep objects and data structures conceptually distinct.
- Use objects to expose behavior while hiding implementation details.
- Use data structures to expose data clearly when behavior is not the point.
- Avoid hybrids that expose data while also pretending to protect behavior.
- Avoid train wrecks and long chains of navigation through object internals.
- Do not expose internal structure unless callers genuinely need that structure.
- Prefer stable, intention-revealing interfaces over leaking implementation details.

## Class and Module Rules

- Keep classes and modules small enough to understand.
- A class or module should have one primary reason to change.
- Group related behavior and data together.
- Separate policies that change for different stakeholders or reasons.
- Hide implementation details behind stable abstractions.
- Prefer cohesive modules where functions and data belong together.
- Split classes when unrelated policies, responsibilities, or change reasons accumulate.
- Do not split classes so aggressively that navigation becomes harder than understanding.
- Treat every new abstraction as a cost that must be justified by change pressure or clarity.

## Design Rules

- Prefer the simplest design that satisfies current requirements and tests.
- Avoid speculative design for features that are not needed.
- Keep the design expressive: the structure should communicate the domain and intent.
- Minimize duplication before minimizing size.
- Minimize size only after preserving clarity, behavior, and tests.
- Use tests as a constraint that keeps design safe to change.
- Apply SOLID principles at module and component level when they improve change tolerance and clarity.

### SOLID-Oriented Rules

- Single Responsibility: separate code that changes for different reasons.
- Open-Closed: prefer adding new code over repeatedly modifying stable existing code when variation is expected.
- Liskov Substitution: ensure interchangeable implementations obey the same behavioral contract.
- Interface Segregation: avoid forcing clients to depend on operations they do not use.
- Dependency Inversion: high-level policy must not depend directly on low-level details; low-level details should depend
  on stable abstractions.

## Architecture Rules

- Separate business rules from frameworks, UI, databases, devices, and external services.
- Keep high-level policy independent from low-level details.
- Draw boundaries where change, ownership, deployment, or external dependency risk requires separation.
- Make dependencies cross architectural boundaries toward the higher-level policy.
- Treat frameworks and external services as details, not as the center of the design.
- Keep business rules testable without external systems.
- Keep UI, database, and infrastructure replaceable where practical.
- Use adapters or boundary interfaces around third-party APIs.
- Limit the number of places that know about external APIs or frameworks.
- Add boundary tests that define how the code expects third-party systems to behave.

## Component Rules

- Group code into components that are cohesive and releasable.
- Keep component dependencies acyclic.
- Avoid dependency cycles between packages, modules, or services.
- Depend in the direction of stability when components have different volatility.
- Keep stable components abstract enough to tolerate change.
- Do not place unrelated responsibilities in the same component merely for convenience.

## Concurrency Rules

- Treat concurrency as a separate design concern.
- Keep concurrent code isolated from non-concurrent business logic.
- Limit the scope of shared mutable data.
- Prefer immutable data, copies, queues, or ownership transfer where possible.
- Keep synchronized or locked sections small.
- Do not assume concurrency bugs are reproducible.
- Write tests that exercise concurrent behavior repeatedly and under stress.
- First make non-concurrent logic correct, then add concurrency.
- Make threaded or asynchronous behavior pluggable and tunable when the runtime context requires it.
- Know the concurrency guarantees of the language, libraries, collections, and execution model being used.

## Testing Rules

- Write tests that define expected behavior before or alongside implementation when practical.
- Keep tests clean; test code must be maintained with the same care as production code.
- Use tests to protect refactoring and cleanup.
- Do not refactor without a way to verify behavior.
- Tests should be fast, isolated, repeatable, self-validating, and timely.
- A test should focus on one action or behavior.
- Prefer clear test names that describe behavior and expected outcome.
- Avoid tests that depend on execution order.
- Avoid tests that require hidden environment state.
- Keep test failures easy to diagnose.
- Use acceptance tests as executable definitions of done for user-facing behavior when they are relevant to the
  requested change.
- Add passing acceptance tests to continuous build or continuous integration when the project already has a suitable
  pipeline and the current change affects that acceptance path.
- Treat a failing continuous build as urgent and stop accumulating additional changes until it is repaired.

## Refactoring Rules

- Refactor in small steps.
- Keep tests passing after each step.
- Start with low-risk improvements: names, extraction, duplication removal, and clearer structure.
- Prefer incremental cleanup over large rewrites.
- Do not redesign from scratch merely because the current code is messy.
- Use cleanup to expose missing tests and hidden bugs.
- Reconsider names after refactoring; better structure often reveals better names.
- Stop when the code is clear enough for the current purpose; do not chase perfect code.

## Continuous Improvement Rules

- Leave touched code cleaner than you found it when doing so is safe and relevant.
- Make one small improvement at a time.
- Do not allow small messes to accumulate until they become architectural constraints.
- Use short development cycles.
- Integrate and verify frequently.
- Keep the build, test, debug, and deployment process fast enough that developers will use it often.
- Maintain productivity by reducing friction in building, testing, debugging, and deploying.

## Review Checklist for Generated Code

Before presenting generated code as final, verify the following:

- The code compiles, runs, or can be validated by the available project checks.
- The behavior is covered by tests or by an explicit verification procedure.
- Names reveal intent and use consistent vocabulary.
- Functions are small and focused.
- Comments are necessary, accurate, and not a substitute for clearer code.
- Formatting follows repository conventions.
- Error handling is explicit and tested.
- Duplication is intentional or removed.
- Dependencies point in the right direction.
- Business rules are not coupled to frameworks, UI, databases, or external services unnecessarily.
- Concurrent code is isolated and tested where applicable.
- The change does not introduce unrelated refactoring.
- The change does not create avoidable regression risk.
- The final result is easier to read, test, and maintain than the starting point.

## When to Ask for Clarification

Ask for clarification before coding when:

- The expected behavior is ambiguous.
- The acceptance criteria are missing.
- The target language, framework, or repository convention is unknown and materially affects the solution.
- Multiple designs are plausible and have materially different tradeoffs.
- A requested optimization conflicts with readability, correctness, or maintainability.
- The requested change may require broad architectural modification.

If the ambiguity is minor and does not block progress, choose the simplest reasonable option and state the assumption.
