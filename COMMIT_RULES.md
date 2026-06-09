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
