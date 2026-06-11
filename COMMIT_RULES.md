# COMMIT_RULES.md

## Purpose

This file defines repository readiness, privacy, and commit message rules for
commits created by an AI coding agent.

## Scope

Apply these rules before creating any commit.

## Repository Readiness and Integrity

- Do not create the commit until the repository readiness checks in this
  section have passed or any skipped check has been reported to the user with
  the reason it was skipped.
- Inspect the local repository state immediately before creating the commit
  with `git status --short --branch` or an equivalent Git status command.
- Do not create the commit while Git reports unresolved merges, unmerged paths,
  rebases, cherry-picks, bisects, or any other in-progress operation that could
  make the commit ambiguous.
- Inspect the staged diff before creating the commit and confirm that every
  staged change belongs in the requested commit.
- Inspect unstaged and untracked files before creating the commit. Do not stage,
  discard, or modify them unless the user requested it or the files are direct
  consequences of the current task.
- Do not create an empty commit unless the user explicitly requests an empty
  commit.
- Run `git diff --cached --check` before creating the commit to detect
  whitespace errors in the staged changes.
- Run `git fsck --full` before creating the commit to verify local repository
  object integrity.
- Do not create the commit if any repository integrity check fails.
- Run the smallest relevant project checks that are available for the changed
  files, such as formatters, linters, type checks, or tests.
- Do not create the commit if a relevant project check fails, unless the user
  explicitly approves committing despite the reported failure.
- Do not claim that remote commit statuses, CI checks, branch protection, or
  hosted review checks are valid unless they were actually inspected.
- If remote or hosted commit status checks are required but cannot be inspected
  from the current environment, report that limitation to the user before
  creating the commit.

## Privacy Guard

- Do not create the commit until every file included in the commit has passed
  this privacy review.
- Never commit a `.env` file containing real environment values, secrets,
  credentials, private URLs, tokens, passwords, or API keys.
- Commit only `.env` templates that contain placeholders or documented example
  values.
- Before committing, review each file included in the commit in its entirety
  for sensitive data, including passwords, API keys, tokens, private keys,
  credentials, private URLs, and real environment-specific values.
- Never commit a file that contains sensitive data.
- The presence of sensitive data must block the commit.
- Notify the user when sensitive data is found.
- When in doubt about whether data is sensitive, ask the user to decide.
- When in doubt about whether data is sensitive, never decide alone that the
  commit is valid.
- A file containing sensitive data must be modified to remove or replace that
  data before it can be committed.

## Commit Message Rules

- Use `.gitmessage` as the commit message template or style reference if it
  exists in the repository.
- Write all commit message content in English.
- Keep the commit subject line at 50 characters or fewer.
- Before writing the commit subject, derive a concise inventory of the material
  staged changes from the staged diff.
- Make the commit subject representative of the full staged change set, not
  only the largest, latest, or originally requested change.
- Do not use a subject that names only one changed file, subsystem, or behavior
  when another staged file, subsystem, or behavior contains material changes.
- For commits with multiple material areas, use either a broader subject that
  captures their shared intent or a short subject that names the main areas.
- Treat a misleadingly narrow commit subject as a commit message defect to fix
  before creating the commit.
- Separate the subject from the body with a blank line.
- Wrap all commit body lines at 72 characters or fewer.
- In the body, briefly describe which files or areas changed and why.
- Write the commit body as wrapped paragraphs, not as one `git commit -m`
  argument per wrapped line. Wrapped lines in the same paragraph must be
  consecutive, with no blank line between them. Use blank lines only between
  the subject and body, or between intentional body paragraphs.
- Do not build a multi-line commit body by passing each body line as a
  separate `git commit -m` argument, because Git treats each `-m` as a
  separate paragraph. Use a commit message file, an editor/template, or one
  body argument containing embedded newlines.

## Conventional Commit Message Rules

### Naming

- Use Conventional Commits as the default commit header format unless a
  higher-priority project instruction, repository-specific `.gitmessage`,
  resolved commitlint configuration, or explicit documented project convention
  requires a different format.
- Write the header as `type[optional scope][optional !]: description` when
  Conventional Commits are used. The `type` and `description` are required;
  the `scope` and `!` marker are optional.
- Use `feat` only when the commit adds a user-visible or project-visible
  feature to the application, library, repository, or tooling.
- Use `fix` only when the commit corrects a bug, broken behavior, invalid
  repository content, or a documented defect.
- Use other commit types only when they are accepted by the repository
  convention. If the repository uses `@commitlint/config-conventional` and does
  not define a narrower `type-enum`, use only accepted types such as `build`,
  `chore`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`, `revert`, `style`,
  and `test`.
- Do not invent a commit type when the repository defines an explicit
  `type-enum`. Choose one of the configured types or ask the user when no
  configured type fits the staged change set.
- Add a scope only when it identifies a meaningful repository area, such as a
  package, module, application, documentation area, configuration area, tooling
  area, or CI component.
- Keep scopes short, lowercase unless the repository convention says otherwise,
  and consistent with existing commit history and the resolved commitlint
  configuration.
- Do not add a scope merely to name a single changed file unless that file is a
  stable repository area in the project convention.
- When multiple scopes are allowed, separate them only with delimiters accepted
  by the repository configuration. Do not mix multi-scope delimiter styles in a
  single commit header.

### Formatting

- Treat the Conventional Commits header as the commit subject line for all
  generic subject-line rules in this file.
- Apply the strictest applicable header or subject length limit from this file,
  `.gitmessage`, the resolved commitlint configuration, and explicit project
  documentation.
- Do not add leading or trailing whitespace to the header, body, or footers.
- Write a non-empty description immediately after the colon-space separator.
  The description must summarize the staged change set directly and must not be
  generic.
- Start the description with a lowercase imperative phrase unless the
  repository history or project convention requires another style.
- Do not end the header description with a period.
- Place the optional body one blank line after the header. Use the body only
  when extra context is useful for understanding motivation, constraints,
  implementation context, migration impact, or user-visible impact.
- Place footers one blank line after the body, or one blank line after the
  header when there is no body.
- Write footers as trailer-like metadata, such as `Refs: #123`,
  `Reviewed-by: Name`, or another project-approved token.
- Use hyphenated footer tokens when a footer token contains multiple words,
  such as `Acked-by`. The token `BREAKING CHANGE` is the only non-hyphenated
  multi-word token allowed by Conventional Commits; `BREAKING-CHANGE` is
  equivalent when used as a footer token.
- Mark breaking changes explicitly with either `!` before the colon or an
  uppercase `BREAKING CHANGE:` or `BREAKING-CHANGE:` footer. Do not require
  both forms unless the resolved commitlint configuration explicitly enforces
  that policy.
- If a `BREAKING CHANGE:` or `BREAKING-CHANGE:` footer is used, describe the
  incompatible behavior and the required migration action when that information
  is known from the change.

### Errors

- Do not force unrelated staged changes into one ambiguous Conventional Commits
  type. Split the staged changes into separate commits when the changes have
  unrelated purposes and can be separated safely.
- If the staged change set cannot be represented by one accurate header, stop
  and ask whether to split the commit or create a broader message that names the
  shared intent.
- Treat a mismatch between the selected type and the staged diff as a commit
  message defect that must be fixed before committing.
- Treat an empty description, invalid type, invalid scope, invalid footer token,
  or invalid breaking-change marker as a blocking commit message defect when
  those rules are required by the repository convention.
- If commitlint rejects a candidate message, read the reported rule names and
  fix the message according to those rules instead of retrying blindly.
- Do not use `revert` unless the commit actually reverts a previous commit or a
  clearly identified previous change.
- For a revert commit, reference the reverted commit hash or change identifier
  when it is known and useful.

### Safety

- Before generating the final commit message, inspect the resolved commitlint
  configuration with `npx commitlint --print-config json` when commitlint is
  available in the repository.
- Treat the resolved commitlint configuration as the repository contract for
  types, scopes, parser presets, length limits, breaking-change policy, and
  footer rules.
- Prefer repository-local commit rules over generic Conventional Commits
  defaults whenever they differ.
- Do not generalize a repository-specific `type-enum`, `scope-enum`, parser
  preset, release policy, or footer convention to another repository unless an
  explicit shared standard says to do so.
- Never bypass commit message validation with `--no-verify` unless the user
  explicitly approves the bypass after seeing the validation failure and its
  risk.
- Do not claim that commitlint, hooks, CI validation, release parsing, or branch
  protection accepted a commit unless the corresponding check was actually run
  or inspected.
- If the repository uses changelog generation, semantic-release, or similar
  tooling, keep the commitlint parser preset and release parser preset aligned
  when the current task modifies commit or release tooling.
- Do not modify hook, CI, release, or commitlint configuration while preparing a
  normal commit unless the user requested that tooling change or it is a direct
  consequence of the current task.

### Tests

- Validate the final candidate commit message with commitlint before running
  `git commit` when commitlint is available or required by the repository.
- For single-line messages, validation by piping the exact message to
  `npx commitlint` is acceptable when the shell command preserves the message
  byte-for-byte.
- For multi-line messages or messages containing shell-sensitive characters,
  write the candidate message to a temporary file and validate that file with
  `npx commitlint --edit <path>` or a repository-defined equivalent.
- Use a `commit-msg` hook for local commit message validation when configuring
  local commit validation. Do not rely on a `pre-commit` hook for commit message
  linting.
- If the current task changes commit validation policy for a shared repository,
  ensure that commit message validation is also enforced in CI when the project
  supports CI changes.
- If commitlint is unavailable, report that message validation could not be run
  and continue only with the static rules in this file and the repository's
  visible templates or documentation.

### Idioms

- Prefer the smallest accurate Conventional Commits type over a broad catch-all
  type.
- Prefer a concise scope over a long descriptive scope when both identify the
  same repository area.
- Use the body to explain why a change was made; do not repeat the header in a
  longer sentence.
- Use footers for structured metadata, issue references, acknowledgements,
  reviews, and breaking-change declarations; do not hide structured metadata in
  free-form body text.
- Use `BREAKING CHANGE:` or `BREAKING-CHANGE:` only for incompatible changes
  that consumers, users, operators, or downstream automation must handle.
- Use `chore` only for maintenance work that does not fit a more specific
  accepted type such as `build`, `ci`, `docs`, `refactor`, `style`, or `test`.
- Use `style` only for formatting or style-only changes that do not alter
  behavior.
- Use `refactor` only for code restructuring that does not add a feature or fix
  a bug.
- Use `perf` only for a change whose purpose is performance improvement.

### Other

- Source basis: Conventional Commits 1.0.0 and commitlint documentation for
  README usage, rules, configuration, local setup, CI setup, and AI-agent
  guidance.
- Keep this section aligned with the repository's resolved commitlint
  configuration and with any repository-local commit message template.
- Review this section whenever the project changes commit types, scopes,
  parser presets, release tooling, changelog tooling, or commit validation
  policy.
- Use these minimal valid headers as examples of shape only; do not copy them
  when they do not represent the staged changes:

  ```text
  feat(parser): add array parsing
  fix(server): send cors headers
  docs: correct changelog typo
  refactor(api): simplify request validation
  feat(api)!: remove deprecated endpoint
  ```
