# DOCUMENTATION_RULES.md

## Purpose

This file defines practical documentation rules for project documentation
created, modified, reviewed, or refactored by an AI coding agent.

Use this file together with `AGENTS.md`, `CODING_RULES.md`, and
`LANGUAGE_RULES.md`:

- `AGENTS.md` governs agent behavior.
- `CODING_RULES.md` governs language-agnostic code quality.
- `LANGUAGE_RULES.md` governs language-, dialect-, and framework-specific code
  rules.
- `DOCUMENTATION_RULES.md` governs human-facing project documentation.

Documentation should help humans understand, install, use, verify, contribute
to, and maintain the project without relying on hidden assumptions.

## Scope

Apply these rules when creating, editing, reviewing, or refactoring project
documentation, especially repository-level files such as `README.md`,
`CHANGELOG.md`, `CONTRIBUTING.md`, and documentation under `docs/`.

Apply these rules to documentation content, structure, links, examples,
metadata, and Markdown quality.

When documentation contains executable code, commands, configuration, or API
examples, keep those examples consistent with the relevant code, language, and
repository rules.

If repository-specific documentation conventions exist, follow them first.

## General Documentation Rules

- Write documentation for human readers first, not for automation.
- State what the project does, why it is useful, and how to start using it
  near the top of the primary documentation.
- Adapt the level of detail to the expected audience, such as users,
  contributors, package consumers, maintainers, reviewers, or operators.
- Keep documentation accurate, current, and grounded in the repository or in
  information explicitly supplied by the user.
- Do not invent project behavior, commands, features, requirements, package
  names, badges, license types, maintainer names, support channels, or external
  services.
- Prefer small, accurate documentation over complete but speculative
  documentation.
- When required information is missing, use a clear placeholder, omit the
  unsupported detail, or state that project-specific input is required.
- Keep coding-agent execution instructions out of human-facing documentation
  when they would clutter the reader experience; place them in `AGENTS.md` or
  an equivalent agent instruction file instead.
- Keep documentation focused on information required to understand, start using,
  verify, and contribute to the project.
- Move long explanations, tutorials, architecture notes, API references, and
  deep maintenance procedures into dedicated files or documentation pages.
- Update documentation when installation, usage, dependencies, support channels,
  public behavior, compatibility, or project status changes.

## README.md

### Existence and Location

- A `README.md` file must exist at the repository root.
- If no `README.md` exists while creating, editing, or refactoring project
  documentation, create a minimal one.
- If no `README.md` exists during a review-only documentation task, report the
  missing file instead of creating it unless the user explicitly asks for
  remediation.
- Place the main repository README at the repository root unless the hosting
  platform or project convention requires another location.
- Do not rely on `.github/README.md` or `docs/README.md` as the only project
  README unless the repository intentionally follows that platform-specific
  behavior.

### Purpose and Audience

- Treat `README.md` as the project's primary human-facing onboarding document.
- Explain what the project does, why it exists, and its main use case near the
  top of the file.
- Make the README useful to a first-time reader who has repository access but
  no hidden project context.
- Keep the README concise enough to scan.
- Link to deeper documentation instead of turning the README into the full
  manual when the project needs extensive detail.

### Required Core Content

- Start with a clear project name or title.
- Add a short description that explains the project's purpose, value, and main
  use case.
- Include installation, setup, build, configuration, or local run instructions
  when the project requires them.
- Include usage instructions with at least one minimal working example when a
  verified example is available.
- Include expected output when it helps readers confirm that a command or code
  example worked.
- Include support or help information when a verified issue tracker,
  documentation site, contact channel, or community link is known.
- Include contributor, maintainer, or ownership information when it is relevant
  and verified.
- Include license information when the repository has a license or when the
  project is open source, published, packaged, or redistributed.
- Document known limitations, unsupported use cases, important caveats, or
  project status when they materially affect users.

### Accuracy Guardrails

- Do not invent project behavior, commands, features, or requirements.
- Do not fabricate installation commands, package names, import paths, service
  names, badges, license type, maintainer names, support channels, screenshots,
  compatibility guarantees, or maintenance status.
- Derive installation and usage instructions from repository files, package
  metadata, existing scripts, tests, documentation, or explicit user input.
- If the correct command is unknown, use a placeholder or state that the command
  requires project-specific input instead of guessing.
- Do not imply stability, compatibility, support, security, or maintenance
  guarantees that are not supported by the project context.
- Check for duplicate sections, conflicting instructions, stale links, broken
  anchors, and unnecessary detail before finalizing the README.

### Minimal README Template

When a root `README.md` is missing, create a minimal README using the structure
below. Replace every placeholder with project-specific content at generation
time. Adapt or remove commands, examples, contribution text, and license text
when the template content is not accurate for the documented project.

When creating a missing minimal root `README.md`, write it in English unless
the user explicitly requests another language.

Do not keep the sample package manager, command, module name, examples, or
license unless they are correct for the project.

````markdown
# <PROJECT-NAME>

<PROJECT-DESCRIPTION>

## Installation

<PROJECT-SPECIFIC-INSTALLATION-INSTRUCTIONS>

```bash
<INSTALL-COMMAND>
```

## Usage

```<LANGUAGE>
<MINIMAL-USAGE-EXAMPLE>
```

## Contributing

<CONTRIBUTION-POLICY>

Please make sure to update tests as appropriate.

## License

[<LICENSE-NAME>](<LICENSE-URL-OR-LOCAL-LICENSE-PATH>)
````

### Installation and Setup

- Write setup steps in execution order.
- List required dependencies, runtime versions, operating system constraints,
  credentials, tokens, environment variables, and external services only when
  they are actually required.
- Prefer copy-paste-ready commands for installation, build, test, and local
  execution when those commands are verified.
- Keep setup instructions reproducible from a clean checkout when practical.
- If setup is complex, keep the README concise and link to dedicated
  installation documentation instead of embedding excessive detail.
- Do not expose secrets, credentials, private URLs, real tokens, or private
  environment values in documentation examples.

### Usage Examples

- Provide the smallest useful usage example directly in the README when a
  verified example is available.
- Prefer examples that readers can run or compare against repository tests,
  sample data, or documented behavior.
- Show expected output when it helps users verify success.
- Use screenshots, diagrams, GIFs, or short visual examples only when they
  clarify behavior better than text.
- Link to advanced examples or tutorials instead of making the README too long.
- Mark illustrative examples clearly when they cannot be executed as written.

### Structure and Navigation

- Use clear Markdown headings in a logical hierarchy.
- Use a table of contents only when the README is long enough to need
  navigation support.
- Keep section names conventional when possible, such as `Installation`,
  `Usage`, `Configuration`, `Testing`, `Contributing`, and `License`.
- Use relative links for repository-local documentation so links keep working
  in clones, forks, and branches.
- Use stable section headings so platform-generated outlines and anchors remain
  useful.
- Avoid oversized READMEs; split large documentation into separate files before
  the README becomes difficult to scan.

### Badges and Metadata

- Use badges only when they communicate useful project status, such as version,
  build status, documentation status, test status, package status, or coverage.
- Place badges near the top when they are useful.
- Do not overload the README with decorative, redundant, stale, or unverifiable
  badges.
- Ensure every badge target is current and points to a maintained resource.
- Do not add badges for services that are not configured in the repository.

### Contribution and Community Information

- State whether contributions are accepted when the policy is known.
- Link to contribution guidelines, code of conduct, development setup, and
  license files when they exist.
- Include test, lint, format, build, or validation commands when contributors
  need them to verify changes and those commands are known.
- Keep contribution details concise in the README and move detailed workflows
  into `CONTRIBUTING.md` or dedicated documentation.
- Do not invent governance, review, support, or community policies.

### Maintenance Status and Limitations

- Document known limitations, unsupported use cases, or important caveats.
- State project status when development is experimental, paused, deprecated,
  archived, unstable, or seeking maintainers.
- Do not imply that a project is production-ready, stable, supported, secure, or
  actively maintained unless the repository context or user confirms it.
- Update the README when project status, dependencies, compatibility,
  installation, usage, or support channels change.

### Data and Reproducibility Contexts

- For datasets, research projects, and reproducible analysis projects, include
  file organization, naming conventions, key contacts, data descriptions, units,
  formats, versioning information, and processing context when applicable.
- Prefer plain text or Markdown for durable README content.
- Avoid proprietary formats for primary README documentation unless project
  requirements justify them.

## CHANGELOG.md

### CHANGELOG.md Existence and Location

- A `CHANGELOG.md` file should exist at the repository root when the project is
  versioned, released, packaged, redistributed, or has user-visible changes that
  need release notes.
- If such a project has no `CHANGELOG.md`, create a minimal one.
- If no `CHANGELOG.md` exists during a review-only documentation task, report
  the missing file instead of creating it unless the user explicitly asks for
  remediation.
- If it is unclear whether a changelog is required, ask before adding release
  history or state the assumption before creating the file.

### Content Rules

- When `CHANGELOG.md` contains release entries, it must list Git tags from the
  most recent tag to the oldest tag.
- Sort tags by Git tag creation date when available, falling back to the tagged
  commit date for lightweight tags.
- If tag chronology is ambiguous or conflicts with the requested release order,
  warn the user before rewriting the changelog.
- Each release section heading must be the exact tag name, using a level-two
  Markdown heading such as `## v1.2.3`.
- Do not rename, normalize, or reformat tag names in section headings.
- Do not add an `Unreleased` section unless the user explicitly requests one.
- Each tag section must list the non-release-preparation commits introduced by
  that tag, ordered from the most recent commit to the oldest commit.
- For every tag except the oldest listed tag, list commits reachable from that
  tag and not reachable from the immediately older listed tag.
- For the oldest listed tag, list commits reachable from that tag unless the
  repository convention or the user defines a different baseline.
- Do not duplicate the same commit under multiple tag sections unless the user
  explicitly requests cumulative tag histories.
- Exclude release-preparation commits from tag commit tables when their only
  purpose is updating `CHANGELOG.md`, release notes, version metadata, or other
  release bookkeeping for the selected tag.
- Do not exclude a commit as release preparation if it also contains functional,
  behavioral, API, documentation, rule, or dependency changes that users or
  maintainers need to see.
- Use Git history as the source of truth for commit checksums, commit titles,
  authors, tag names, tag order, and commit order.
- Do not invent release dates, versions, migration steps, compatibility notes,
  security impact, commit messages, commit authors, or missing tag history.
- Link to release tags, pull requests, issues, or migration documentation only
  when those targets exist or are explicitly supplied.
- Keep entries concise and mechanically traceable to the repository history.

### Tagged Entry Table Format

- Under each tag heading, render commits as a Markdown table with exactly these
  three columns in this order: `References`, `Description`, `Author(s)`.
- Use this exact table header and separator:

  ```markdown
  | References | Description | Author(s) |
  | --- | --- | --- |
  ```

- In the `References` column, use a short unique commit checksum unless the
  repository convention or user requires full commit checksums.
- In the `Description` column, use the commit title.
- In the `Author(s)` column, use the commit author name from Git history.
- Preserve commit titles accurately, but escape Markdown table separators when
  needed so the table remains valid.
- Do not add extra columns, category headings, bullet lists, prose summaries, or
  per-section metadata inside tag sections unless the user explicitly requests
  them.
- Use the following structure for each tag section:

  ```markdown
  ## vX.Y.Z

  | References | Description | Author(s) |
  | --- | --- | --- |
  | <COMMIT-CHECKSUM-1> | <COMMIT-TITLE-1> | <COMMIT-AUTHOR-1> |
  | <COMMIT-CHECKSUM-2> | <COMMIT-TITLE-2> | <COMMIT-AUTHOR-2> |
  | <COMMIT-CHECKSUM-3> | <COMMIT-TITLE-3> | <COMMIT-AUTHOR-3> |
  ```

### Minimal CHANGELOG Template

When a changelog is required but missing, create a minimal file using the
structure below and adapt it to the project context. Do not add tag sections
until real repository tags and commits are available.

```markdown
# Changelog

All notable changes to this project will be documented in this file.

No tagged release entries have been documented yet.
```

## Markdown Documentation Quality

### Linting

- Every Markdown file in the repository must pass `markdownlint` before
  documentation changes are presented as final.
- Run `markdownlint` against all repository Markdown files, not only the files
  changed in the current task, so formatting and syntax rules stay consistent.
- Use the repository's existing `markdownlint` configuration when one exists.
- Do not disable or relax `markdownlint` rules to make a change pass unless the
  user explicitly requests that configuration change.
- If `markdownlint` is not installed, unavailable, or inaccessible, report that
  limitation and use a conservative fallback check before finalizing.
- The fallback check must at minimum inspect Markdown syntax, heading order,
  duplicate headings, blank lines around headings and tables, trailing
  whitespace, malformed lists, invalid tables, malformed links or images,
  unclosed code fences, and missing language identifiers on known-language
  fenced code blocks.
- State that the fallback check does not replace a successful `markdownlint`
  run.

### Naming

- Use clear, unique, and descriptive headings so generated anchors remain
  predictable.
- Use one level-one heading as the document title unless the target platform
  requires another structure.
- Use descriptive link text that remains understandable outside its surrounding
  sentence.
- Avoid vague link labels such as `here`, `link`, or raw URLs as visible link
  text.
- Use stable, readable, repository-safe image filenames.
- Prefer hyphenated image filenames when the target documentation pipeline has
  known rendering issues with underscores.
- Keep front matter keys explicit, stable, and documented when front matter is
  required.

### Formatting

- Prefer simple, portable, human-readable Markdown over complex
  renderer-specific syntax.
- Keep Markdown source readable in plain text, not only correct after
  rendering.
- State the target Markdown dialect when output depends on platform-specific
  rendering behavior.
- Do not assume GitHub Flavored Markdown, Azure DevOps Markdown, Adobe Markdown
  extensions, or another dialect unless the target renderer is explicitly
  known.
- Use platform-specific Markdown extensions only when the target platform
  supports them and the document is intended for that platform.
- Use valid Markdown syntax.
- Start main content with level-two headings after the document title.
- Add a short introduction after the title when the document explains a
  process, reference, or concept.
- Put a space after heading markers, for example `## Usage`, not `##Usage`.
- Prefer ATX headings using `#`, `##`, and `###`; avoid Setext-style headings
  for maintainability.
- Keep heading levels hierarchical; do not skip levels without a structural
  reason.
- Put blank lines before and after headings and horizontal rules for better
  renderer compatibility.
- Separate paragraphs with a blank line.
- Keep paragraphs left-aligned unless indentation is required by Markdown
  syntax.
- Avoid trailing whitespace entirely.
- Do not rely on trailing spaces to create line breaks.
- Use hard line breaks only when the rendered layout genuinely requires them.
- Use one unordered-list marker style consistently within a document.
- Use ordered lists for ordered procedures and unordered lists for unordered
  collections.
- Use lazy numbering with `1.` only when the target renderer supports it and
  the list may change frequently.
- Use explicit sequential numbering for short, stable ordered lists when it
  improves source readability.
- Keep nested list indentation consistent.
- Avoid deeply nested lists when headings or separate sections would be
  clearer.
- Prefer lists and tables only when they improve scanning or comparison.
- Use inline code spans for commands, filenames, field names, literals,
  placeholders, and syntax examples.
- Use fenced code blocks for commands, configuration examples, and code
  snippets.
- Use language identifiers on fenced code blocks when the language or shell is
  known.
- Avoid indented code blocks when fenced code blocks are clearer.
- Keep code blocks copy-safe; avoid prompts, ellipses, or hidden assumptions
  unless they are intentionally part of the example.
- Escape or quote placeholders that could be interpreted as HTML or Markdown
  syntax.
- Prefer inline links for short, readable links.
- Use reference links when a long URL would damage source readability or when
  the same URL is repeated.
- Keep internal link strategy consistent with the repository or documentation
  platform.
- Prefer relative links for repository files when the repository and renderer
  support them.
- Provide meaningful alt text for informative images.
- Add captions or surrounding text when an image is necessary to understand the
  document.
- Use Markdown tables only for compact, simple, tabular data.
- Add a blank line before Markdown tables to improve renderer compatibility.
- Keep table columns short enough to remain readable in source form.
- Avoid complex multi-paragraph content inside table cells.
- Avoid lists inside table cells unless the target renderer is known to support
  them cleanly.
- Prefer headings, lists, or definition-style sections over oversized tables.
- Add front matter only when the target toolchain requires metadata.
- Prefer simple key-value front matter before introducing nested metadata
  structures.
- Validate front matter syntax separately from Markdown content.

### Errors

- Treat malformed Markdown syntax, broken heading hierarchy, malformed links,
  malformed image syntax, and unclosed code fences as defects to fix before
  finalizing Markdown.
- Treat duplicate headings as defects when generated anchors must remain
  predictable or when the target platform generates conflicting anchors.
- Treat missing language identifiers on known-language fenced code blocks as
  defects unless the repository style intentionally omits them.
- Treat invalid or unsupported renderer-specific syntax as a defect when the
  target renderer is unknown or different from the syntax source.
- Do not invent link targets, image paths, anchors, metadata fields, badges,
  commands, or external references.
- Verify anchors and relative paths when generating repository documentation.
- Do not add undocumented metadata fields for speculative future use.

### Safety

- Treat Markdown from users or external systems as untrusted input.
- Prefer Markdown syntax over raw HTML.
- Use raw HTML only when Markdown cannot express the required structure and the
  target renderer allows HTML.
- Do not emit raw HTML in security-sensitive or user-generated Markdown
  pipelines unless sanitization is guaranteed.
- Disable raw HTML in Markdown parsers when it is not required.
- Sanitize rendered HTML before displaying user-generated Markdown.
- Apply a whitelist approach for allowed tags and attributes when HTML output
  must be supported.
- Validate links and reject unsafe protocols such as `javascript:` or `data:`.
- Do not embed external images unless the project allows external dependencies.
- Do not store secrets, API keys, credentials, private tokens, passwords, or
  private URLs in Markdown examples.
- Keep Markdown parsing dependencies updated when dependency maintenance is
  part of the project scope.

### Tests

- Validate generated Markdown syntax before presenting it as final when a
  validator or renderer check is available.
- Check heading order, duplicate headings, blank lines around headings,
  trailing whitespace, malformed lists, invalid tables, and unclosed code
  fences.
- Check that fenced code blocks use language identifiers when the language is
  known.
- Check links, anchors, and repository-relative paths when the documentation
  will be stored in a repository.
- Check front matter with a front matter or YAML validator when front matter is
  present.
- Check renderer-specific extensions against the declared target renderer
  before using callouts, admonitions, task lists, footnotes, heading IDs, or
  other non-portable syntax.
- When editing existing Markdown, verify that the change matches the existing
  repository documentation style.
- Check image paths, alt text, and external image usage against repository
  documentation rules.

### Idioms

- Generate the smallest Markdown structure that satisfies the request.
- Prefer consistent Markdown patterns over local cleverness.
- Use explicit Markdown syntax instead of invisible formatting whenever
  possible.
- Do not add speculative sections.
- Do not duplicate the same rule or content under multiple headings.
- Do not mix tutorial content with coding-agent rules unless the user requested
  a tutorial.
- Keep each Markdown rule, example, and section action-oriented and testable.
- Use headings to structure meaning, not merely to control visual size.
- Keep documentation source maintainable for human review, diffs, and version
  control.

### Other

- Treat callouts, admonitions, task lists, footnotes, heading IDs, and other
  Markdown extensions as platform-specific unless explicitly supported.
- Document any required Markdown extension in the file or project rules.
- Prefer plain Markdown over proprietary or tool-specific formats for durable
  repository documentation unless project requirements justify otherwise.

## Review Checklist for Documentation

Before presenting documentation changes as final, verify the following:

- Required root documentation files exist for the project context.
- The README is accurate, human-facing, and useful to a first-time reader.
- Missing information is handled with clear placeholders or explicit notes
  instead of guesses.
- Installation, setup, usage, test, and build commands are verified or clearly
  marked as project-specific placeholders.
- Code examples match the project language, API, package names, and current
  behavior.
- Repository-local links are relative and point to existing targets when
  possible.
- External links, badges, support channels, and documentation references are not
  stale or fabricated.
- License, contribution, maintainer, and support information is included only
  when verified or explicitly supplied.
- Changelog entries, when present, use exact tag headings in reverse
  chronological order and the required three-column commit table format.
- Long or specialized content is moved out of the README when it makes the
  primary onboarding document hard to scan.
- `markdownlint` passes for every Markdown file, or its unavailability is
  reported with the conservative fallback checks that were performed.
- Markdown renders cleanly and follows the repository's documentation style.
