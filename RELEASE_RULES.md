# RELEASE_RULES.md

## Purpose

This file defines Git tag creation rules for tags created by an AI coding
agent.

## Scope

Apply these rules before creating any Git tag.

## Repository Readiness and Integrity

- Do not create the tag until the repository readiness checks in this section
  have passed or any skipped check has been reported to the user with the
  reason it was skipped.
- Inspect the local repository state immediately before creating the tag with
  `git status --short --branch` or an equivalent Git status command.
- Do not create the tag while Git reports unresolved merges, unmerged paths,
  rebases, cherry-picks, bisects, or any other in-progress operation that could
  make the tag target ambiguous.
- Do not create the tag while the working tree contains uncommitted changes or
  untracked files, unless the user explicitly approves creating the tag despite
  those reported files.
- Run `git fsck --full` before creating the tag to verify local repository
  object integrity.
- Do not create the tag if any repository integrity check fails.
- Identify the exact commit SHA that the tag will point to before creating the
  tag.
- If commit status checks, CI results, branch protection, or hosted review
  checks are required for the tag target, inspect them before creating the tag.
- Do not claim that commit status checks, CI results, branch protection, or
  hosted review checks are valid unless they were actually inspected.
- If required remote or hosted checks cannot be inspected from the current
  environment, report that limitation to the user before creating the tag.

## Version Rules

- Use strict SemVer for version numbers.
- Use the `MAJOR.MINOR.PATCH` version format unless a valid SemVer pre-release
  or build metadata identifier is explicitly required.

## Bump Rules

- Given a version number `MAJOR.MINOR.PATCH`, increment `MAJOR` when making
  incompatible API changes.
- Given a version number `MAJOR.MINOR.PATCH`, increment `MINOR` when adding
  functionality in a backward-compatible manner.
- Given a version number `MAJOR.MINOR.PATCH`, increment `PATCH` when making
  backward-compatible bug fixes.
- Use pre-release labels and build metadata only as valid SemVer extensions to
  the `MAJOR.MINOR.PATCH` format, and only when they are explicitly required.
- Before creating any tag, validate the selected version number with this
  ECMAScript-compatible regular expression. Validate the version number without
  the leading lowercase `v` tag prefix:

  ```regex
  ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$
  ```

- Do not create the tag if the selected version number fails the regular
  expression validation.

## Remote Tag Rules

- When a tag will be pushed to a remote repository, inspect the remote tags
  before selecting the version and again immediately before pushing the tag.
- Do not push the tag if the same tag already exists in the remote repository.
- If remote SemVer tags exist, include them when identifying the highest
  existing SemVer version for the requested bump type.
- Stop and ask before creating or pushing the tag if the selected local version
  is lower than the highest matching remote SemVer version, equal to an
  existing remote version, or otherwise conflicts with the version required by
  the requested bump type.

## Changelog Rules

- Before creating any Git tag, read and follow the `CHANGELOG.md` rules in
  `DOCUMENTATION_RULES.md`.
- When `DOCUMENTATION_RULES.md` requires a root `CHANGELOG.md`, do not create
  the tag until that file exists.
- Before creating a tag, verify that `CHANGELOG.md` contains a section for the
  selected tag using the exact selected tag name.
- Populate the selected tag section from Git history using the tag target
  commit as the upper bound and the immediately older tag as the lower bound.
- If the tag target is a release-preparation commit, use the commit immediately
  before that release-preparation commit as the effective upper bound for the
  changelog table.
- Exclude release-preparation commits from the selected tag's changelog table
  as defined by `DOCUMENTATION_RULES.md`.
- Do not combine release-preparation changes with functional, behavioral, API,
  documentation, rule, or dependency changes when preparing a tag.
- Do not create the tag if the selected tag's changelog section is missing,
  malformed, stale, or based on unverified commit data.
- If the changelog must be changed for the selected tag, make and commit the
  changelog update before creating the tag unless the user explicitly approves
  tagging with uncommitted changelog changes.

## Tag Rules

Before creating a tag:

- Inspect existing Git tags.
- Consider only tags matching a lowercase `v` prefix followed by a strict
  SemVer version, such as `v1.0.1`.
- If no matching tags exist, ask for the initial strict SemVer version before
  creating a tag, then use that version as the tag version.
- If matching tags exist, identify the highest existing SemVer version and
  increment it using the requested SemVer bump type: major, minor, or patch.
- If matching tags exist and no bump type is specified, ask before creating the
  tag.
- Create lightweight tags unless the user explicitly requests annotated tags.
- Create the tag using a lowercase `v` prefix followed by the selected strict
  SemVer version.
