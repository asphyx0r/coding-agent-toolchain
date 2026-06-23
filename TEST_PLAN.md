# Test Plan

This document defines the complete test plan for Coding Agent Toolchain. It is
grounded in the repository contract from `README.md`, `config/tools.yaml`, and
the two platform scripts. The plan covers every usage combination by requiring
each combination to be either tested directly, mapped to a tested equivalence
class, marked invalid by contract, or marked not applicable with a reason.

## Goals

- Verify the Windows and Linux installers from their public command-line
  contract through their observable outputs, exit codes, and filesystem effects.
- Account for every combination of platform, command mode, option spelling,
  manifest shape, prefix state, tool state, installer kind, and removal state.
- Keep routine tests isolated from the real user profile, real `PATH`, package
  managers, network downloads, and destructive filesystem operations.
- Separate offline deterministic tests from optional network smoke tests.

## Non-Goals

- Do not require every routine test run to download upstream release assets or
  install real packages.
- Do not test third-party package manager correctness beyond the exact command,
  arguments, fallback, and error handling expected by this project.
- Do not change script behavior only to make the plan easier to automate.

## Source Contracts

| Contract area | Authoritative source | Required coverage |
| --- | --- | --- |
| Public options and examples | [`README.md`](README.md) | CLI parsing, help output, documented examples |
| Default directories and prefixes | [`README.md`](README.md) | Default path, custom prefix, path publication, removal scope |
| Manifest schema and tool list | [`config/tools.yaml`](config/tools.yaml) | Manifest validation, each canonical tool, each declared installer kind |
| Windows implementation | [`scripts/install-tools.ps1`](scripts/install-tools.ps1) | PowerShell parsing, installer dispatch, version checks, removal safety |
| Linux implementation | [`scripts/install-tools.sh`](scripts/install-tools.sh) | Bash parsing, installer dispatch, version checks, removal safety |
| Repository quality gates | [`README.md`](README.md#verification) | Markdown, YAML, Bash, ShellCheck, PowerShell parser, PSScriptAnalyzer |

## Completion Criteria

The implemented offline runner is complete for the structural coverage contract
when all criteria below are true. It generates a deterministic matrix inventory
on demand and validates the generator count and row shape without requiring
routine runs to persist or exhaustively validate every generated row.

- Every expected axis in the combination model is documented with values.
- The inventory template exposes every required column.
- The generated inventory reports the full cartesian row count and emits rows
  with every required template column without storing a static inventory file.
- Accepted `Coverage` status forms are documented, and the example row uses an
  accepted status.
- Every referenced test ID resolves to a documented direct test or structural
  check.
- Every platform-specific behavior is tested on its owning platform or marked as
  platform-specific and not applicable on the other platform.
- Every destructive scenario uses an isolated temporary home, profile, or prefix
  and proves that unmanaged paths are left untouched.
- The documented verification commands pass, or the unavailable command is
  reported with the fallback that was run.

## Combination Model

The axes in this section define the target model for current direct tests and a
generated matrix inventory. A generated row is valid only when all axes have a
value and the `Coverage` field is one of `direct_test`,
`equivalent:<test-id>`, `invalid:<reason>`, or `not_applicable:<reason>`.

| Axis | Values | Notes |
| --- | --- | --- |
| Platform | `windows`, `linux` | Windows uses `install-tools.ps1`; Linux uses `install-tools.sh`. |
| Execution identity | normal user, administrator, root | Administrator and root runs must be rejected before any state-changing behavior. |
| Command mode | `help`, `install`, `remove` | `install` is the default mode when neither help nor remove is selected. |
| Option form | short, long, mixed, unknown, missing value | Applies to `-c`, `--config`, `-v`, `--verbose`, `-d`, `--dry-run`, `-r`, `--remove`, `-p`, `--prefix`, `-h`, `--help`, and `--check-path`. |
| PowerShell common option | absent, `-Verbose` | Windows must also cover the native PowerShell verbose common parameter. |
| Verbose flag | off, on | Must prove debug output is gated by explicit verbosity. |
| Dry-run flag | off, on | Must prove no installs, downloads, profile writes, `PATH` writes, or removals occur. |
| Check-path flag | off, on | Must prove path verification output appears only in installation flow. |
| Config path | default, custom valid, missing, unreadable, non-YAML, malformed YAML, unsupported schema | Malformed means unsupported line shape or invalid manifest structure for the scripts' parser. |
| Tool entry shape | complete, missing executable, missing platform installer, missing kind, unsupported key, unsupported kind | Includes platform-specific skipped tools. |
| Prefix | absent, valid absolute, valid relative under user root, user root, outside user root, nonexistent, syntactically invalid, uncreatable, missing argument | Prefix rules differ only in path syntax between platforms. |
| Filesystem boundary | user root, outside user root, system directory, read-only directory | Tests must prove only user-scoped writable paths can be modified. |
| Tool availability | absent, present with version, present with version failure, install succeeds, install fails, install succeeds but command remains missing | Includes module availability for PowerShell Gallery tools. |
| Installer kind | `pip`, `python_user`, `uv_tool`, `npm_global`, `powershell_gallery`, `brew`, `winget`, `chocolatey`, `direct_binary`, `github_release_asset`, `portable_archive`, `direct_installer`, `appimage_extract`, `source_make`, `conda_forge`, unsupported | Some kinds are canonical only on one platform but still need unsupported-kind coverage elsewhere. |
| Archive shape | none, zip, tar.gz, tar.xz, seven_zip, AppImage, missing expected executable | Applies only to archive, direct binary, release asset, and AppImage paths. |
| Download or release lookup | success, command failure, no matching asset, missing required field | Must be mocked for routine tests. |
| Published command state | absent, managed shim or symlink, unmanaged file, unmanaged symlink, stale managed command | Covers Windows shims and Linux symlinks. |
| Removal state | marker present, marker missing, target missing, outside user root, shared directory, current user root, elevated user, obsolete path entry | Applies only to remove mode. |
| Expected result | exit zero, exit nonzero, status `Present`, `Installed`, `DryRun`, `Skipped`, `Missing`, `Failed`, `Removed` | Summary output must match the branch. |

## Combination Inventory Template

Use this template for generated or manually maintained inventory rows.
`tests/generate-combination-inventory.ps1` reads the combination model and
emits deterministic CSV rows with these columns. Routine validation checks the
generator count and a small bounded row sample; it does not store a
materialized row for every cartesian combination.

| ID | Platform | Mode | Options | Config | Prefix | Tool State | Installer | File State | Expected | Coverage |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `MATRIX-EXAMPLE` | `linux` | `install` | `--dry-run --check-path` | custom valid | valid absolute | absent | `pip` | none | exit zero, dry-run and simulated path output | `direct_test` |

## Required Direct Tests

The direct tests below are the minimum set. They are allowed to be implemented
with Pester, Bats, shell scripts, or another project-approved runner, but each
test must remain self-validating and isolated.

Unless a test explicitly names administrator or root execution, run it as a
normal user. Elevated-identity behavior belongs only to `SAFETY-*` and
remove-mode elevation tests, so normal CLI behavior and elevation rejection do
not overlap.

### Combination Accounting Tests

| ID | Scope | Scenario | Expected result |
| --- | --- | --- | --- |
| `MATRIX-001` | Axes | Verify every expected axis from the combination model. | No expected axis is missing or empty. |
| `MATRIX-002` | Inventory template | Validate the inventory template columns. | The template exposes every required column. |
| `MATRIX-003` | Coverage status | Validate accepted `Coverage` status forms and the example row. | The contract lists every accepted status form, and the example uses one. |
| `MATRIX-004` | References | Validate every referenced test ID. | Each reference resolves to a documented direct test or structural check. |
| `MATRIX-005` | Coverage boundary | Document that full cartesian row persistence and exhaustive validation are not required for routine runs. | The test plan states that routine runs do not persist or exhaustively validate every generated row. |
| `MATRIX-006` | Canonical tools | Cross-check every canonical tool against documented tool coverage rows. | Each tool appears once, declared platform kinds match the manifest, and each kind maps to required dispatch or unavailable coverage. |
| `MATRIX-007` | Generated inventory | Validate the inventory generator existence, cartesian count, and row shape. | The generator reports a positive count and emits CSV rows with the required columns. |

### Static Quality Tests

| ID | Scope | Scenario | Expected result |
| --- | --- | --- | --- |
| `STATIC-001` | Markdown | Run repository Markdown lint. | All Markdown files pass. |
| `STATIC-002` | YAML | Run repository YAML lint against `.yamllint`, `.markdownlint-cli2.yaml`, `config/tools.yaml`, `.github/workflows/validation.yml`, and `.github/dependabot.yml`. | YAML syntax and style pass. |
| `STATIC-003` | Bash | Run `bash -n scripts/install-tools.sh`. | Bash syntax passes. |
| `STATIC-004` | Bash | Run `shellcheck scripts/install-tools.sh`. | No ShellCheck findings. |
| `STATIC-007` | Bash | Run `shfmt -d -i 2 scripts/install-tools.sh` when available. | No formatting diff. |
| `STATIC-005` | PowerShell | Parse PowerShell scripts with the PowerShell parser. | No parse errors. |
| `STATIC-006` | PowerShell | Run `Invoke-ScriptAnalyzer` against PowerShell scripts when available. | No analyzer findings. |

### Supply Chain Trust Tests

| ID | Scope | Scenario | Expected result |
| --- | --- | --- | --- |
| `SUPPLY-001` | Installer trust | Cross-check every canonical installer kind against the documented verification strategy table. | Every canonical installer kind has one `trusted_upstream`, `checksum`, or `signature` strategy. |
| `SUPPLY-002` | Artifact checksums | Cross-check every canonical direct artifact installer against manifest integrity fields. | Every direct artifact installer has a fixed URL or `release_tag` plus a valid SHA256 checksum. |
| `SUPPLY-003` | Moving selectors | Scan canonical direct artifact installers for moving release selectors. | No schema `2` direct artifact URL or `release_tag` uses `latest`, `stable`, or `master`. |

### Installer Verification Strategies

Accepted strategies are `trusted_upstream`, `checksum`, and `signature`.

| Installer kind | Verification strategy |
| --- | --- |
| `appimage_extract` | `checksum` |
| `conda_forge` | `trusted_upstream` |
| `direct_binary` | `checksum` |
| `direct_installer` | `checksum` |
| `github_release_asset` | `checksum` |
| `npm_global` | `trusted_upstream` |
| `pip` | `trusted_upstream` |
| `portable_archive` | `checksum` |
| `powershell_gallery` | `trusted_upstream` |
| `source_make` | `checksum` |

### Safety Boundary Tests

These tests harden error handling around privilege, filesystem boundaries, and
side effects. They add coverage to the existing CLI, prefix, installation, and
removal tests; they do not replace those tests.

| ID | Platform | Scenario | Expected result |
| --- | --- | --- | --- |
| `SAFETY-001` | linux | Run every public mode as `root`: `-h`, `--help`, default install, `--dry-run`, `--check-path`, and `--remove`. | Each invocation exits nonzero before manifest processing, installation, PATH checks, removal, downloads, profile writes, or filesystem changes. |
| `SAFETY-002` | windows | Run every public mode as Administrator: `-h`, `--help`, default install, `--dry-run`, `--check-path`, and `--remove`. | Each invocation exits nonzero before manifest processing, installation, PATH checks, removal, downloads, profile writes, or filesystem changes. |
| `SAFETY-003` | both | Point prefix, resolved install root, command publication path, and removal target at a system directory such as `/usr`, `/etc`, `C:\Windows`, or `C:\Program Files`. | The run exits nonzero and does not create, modify, or delete anything in the system directory. |
| `SAFETY-004` | both | Point prefix, resolved install root, command publication path, and removal target outside the current user's home or profile but outside a system directory. | The run exits nonzero and does not create, modify, or delete anything outside the current user's home or profile. |
| `SAFETY-005` | both | Snapshot all candidate side-effect locations before an invalid config, invalid prefix, root or administrator run, and refused removal. | The after-run snapshot is identical for every location except allowed diagnostic output streams. |
| `SAFETY-006` | both | Run dry-run mode with config paths, prefixes, installer kinds, and removal targets that would otherwise be state-changing if accepted. | The dry-run exits according to validation rules and never creates, modifies, or deletes files, directories, profile entries, PATH entries, shims, symlinks, markers, downloads, or archives. |
| `SAFETY-007` | both | Attempt to remove a marked-looking directory whose resolved physical path escapes the user root through a symlink, junction, bind mount, or equivalent platform feature. | Removal is refused and the escaped target remains unchanged. |

### CLI Parsing Tests

| ID | Platform | Scenario | Expected result |
| --- | --- | --- | --- |
| `CLI-001` | both | Run `-h` and `--help`. | Exit zero; usage includes version and all supported options; no manifest read is required. |
| `CLI-002` | both | Run default install mode with no arguments and a controlled valid default config. | The default config path is used and tools are processed. |
| `CLI-003` | both | Run `-c <path>` and `--config <path>`. | The supplied config path is used. |
| `CLI-004` | both | Run `-c` and `--config` without a value. | Exit nonzero with a clear missing-path message. |
| `CLI-005` | both | Run `-p <path>` and `--prefix <path>`. | The supplied prefix is normalized and used when valid. |
| `CLI-006` | both | Run `-p` and `--prefix` without a value. | Exit nonzero with a clear missing-prefix message. |
| `CLI-007` | both | Run `-v` and `--verbose`. | Debug traces are emitted. |
| `CLI-008` | windows | Run native `-Verbose`. | Debug traces are emitted through the Windows verbosity path. |
| `CLI-009` | both | Run `-d` and `--dry-run`. | Dry-run mode is enabled and no state changes occur. |
| `CLI-010` | both | Run `-r` and `--remove`. | Remove mode runs instead of install mode. |
| `CLI-011` | both | Run `--check-path` in install mode. | Path verification table is printed after tool processing. |
| `CLI-012` | both | Run `--check-path --remove`. | Remove mode exits through removal flow; install path verification is not printed. |
| `CLI-013` | both | Run `--dry-run --check-path`. | Dry-run tool statuses are reported and path verification shows simulated status. |
| `CLI-014` | both | Run an unknown option. | Exit nonzero with usage or an unknown-option message. |
| `CLI-015` | both | Run mixed short and long options in a different order. | Results match the same normalized option set. |
| `CLI-016` | both | Run help combined with valid flags before help. | Help exits zero and state-changing behavior is not run. |
| `CLI-017` | both | Run an invalid option before help. | The invalid option fails before help can mask it. |
| `CLI-018` | both | Run `-c <missing-file>`. | Exit nonzero with a clear config-file-not-found message; no install, removal, PATH, download, marker, profile, shim, or symlink operation runs. |
| `CLI-019` | both | Run `--config <missing-file>`. | Exit nonzero with a clear config-file-not-found message; no install, removal, PATH, download, marker, profile, shim, or symlink operation runs. |
| `CLI-020` | both | Run `-c <unreadable-yaml-file>`. | Exit nonzero with a clear config-unreadable message; no tool processing or state change occurs. |
| `CLI-021` | both | Run `--config <unreadable-yaml-file>`. | Exit nonzero with a clear config-unreadable message; no tool processing or state change occurs. |
| `CLI-022` | both | Run `-c <non-yaml-file>`. | Exit nonzero with a clear invalid-manifest or non-YAML message; no tool processing or state change occurs. |
| `CLI-023` | both | Run `--config <non-yaml-file>`. | Exit nonzero with a clear invalid-manifest or non-YAML message; no tool processing or state change occurs. |
| `CLI-024` | both | Run `-p <nonexistent-prefix>`, `-p <syntactically-invalid-prefix>`, and `-p <uncreatable-prefix>`. | Each run exits nonzero with a clear invalid-prefix message and performs no install, removal, PATH, download, marker, profile, shim, or symlink operation. |
| `CLI-025` | both | Run `--prefix <nonexistent-prefix>`, `--prefix <syntactically-invalid-prefix>`, and `--prefix <uncreatable-prefix>`. | Each run exits nonzero with a clear invalid-prefix message and performs no install, removal, PATH, download, marker, profile, shim, or symlink operation. |

### Manifest Parsing Tests

| ID | Platform | Scenario | Expected result |
| --- | --- | --- | --- |
| `MANIFEST-001` | both | Canonical `config/tools.yaml`. | All canonical tools load in manifest order. |
| `MANIFEST-002` | both | Missing manifest path. | Exit nonzero with configuration-file-not-found message. |
| `MANIFEST-003` | both | Unsupported `schema_version`. | Exit nonzero with expected schema version message. |
| `MANIFEST-004` | both | Manifest with no tools. | Exit nonzero with no-tools message. |
| `MANIFEST-005` | both | Tool without executable. | Exit nonzero naming the affected tool. |
| `MANIFEST-006` | both | Installer property outside a platform block. | Exit nonzero with installer-property context. |
| `MANIFEST-007` | both | Unsupported installer key. | Exit nonzero naming the key and line. |
| `MANIFEST-008` | both | Unsupported line shape or indentation. | Exit nonzero naming the line. |
| `MANIFEST-009` | both | Missing current-platform installer. | Tool is skipped as unavailable on that platform. |
| `MANIFEST-010` | both | Missing current-platform installer kind. | Tool is skipped as unavailable on that platform. |
| `MANIFEST-011` | both | Quoted values and multiple `version_args`. | Values are unquoted and version arguments preserve order. |
| `MANIFEST-012` | linux | Ghostscript `conda_forge` manifest compatibility path. | Linux defaults are normalized to the source-build path with fallback. |
| `MANIFEST-013` | both | Existing YAML config file is present but unreadable by the current user. | Exit nonzero with a clear unreadable-config message before any tool entry is processed. |
| `MANIFEST-014` | both | Existing config path points to a non-YAML file such as plain text, JSON, binary content, or another unsupported format. | Exit nonzero with a clear invalid-manifest or non-YAML message before any tool entry is processed. |
| `MANIFEST-015` | both | Existing config file has YAML extension but invalid YAML structure for this manifest contract. | Exit nonzero with a clear invalid-manifest message before any tool entry is processed. |
| `MANIFEST-016` | both | Existing command with `version_check: command_available`. | The command is treated as present without executing it as a version command. |

### Installer Dispatch Tests

Each installer kind must be tested with a synthetic one-tool manifest and mocked
external commands. The expected command arguments are part of the assertion.

| ID | Platform | Installer kind | Expected result |
| --- | --- | --- | --- |
| `DISPATCH-001` | both | `pip` | Uses the user-scoped pip installation path, publishes the command as needed, and verifies version. |
| `DISPATCH-002` | both | `python_user` | Uses Python user installation logic or the platform-specific supported equivalent. |
| `DISPATCH-003` | both | `uv_tool` | Uses the user-scoped uv tool path or reports unsupported prerequisites clearly. |
| `DISPATCH-004` | both | `npm_global` | Uses the managed npm prefix and verifies the npm-installed command. |
| `DISPATCH-005` | both | `powershell_gallery` | Detects and installs the current-user PowerShell module through `pwsh` or PowerShell; Linux skips the tool when `pwsh` is unavailable or unusable. |
| `DISPATCH-006` | both | `brew` | Calls the brew installer branch or reports platform-specific unavailability. |
| `DISPATCH-007` | both | `winget` | Calls the winget branch or reports platform-specific unavailability. |
| `DISPATCH-008` | both | `chocolatey` | Calls the Chocolatey branch and treats user-scope failure as installation failure. |
| `DISPATCH-009` | both | `direct_binary` | Downloads or copies the binary into the managed install directory and publishes the command. |
| `DISPATCH-010` | both | `github_release_asset` | Resolves the latest release asset, extracts or copies it, and publishes the command. |
| `DISPATCH-011` | both | `portable_archive` | Extracts the archive, resolves `bin_path`, and verifies the installed command. |
| `DISPATCH-012` | windows | `direct_installer` | Downloads and runs the installer with target arguments, then verifies the installed command. |
| `DISPATCH-013` | linux | `appimage_extract` | Extracts the AppImage and publishes the Linux command symlink. |
| `DISPATCH-014` | linux | `source_make` with compiler | Builds from source under the managed prefix and verifies the command. |
| `DISPATCH-015` | linux | `source_make` without compiler | Falls back to `conda_forge` for Ghostscript. |
| `DISPATCH-016` | linux | `conda_forge` | Installs through the managed micromamba runtime and verifies the command. |
| `DISPATCH-017` | both | unsupported kind | Tool result is `Failed` with unsupported-kind detail. |
| `DISPATCH-018` | linux | `direct_binary` pointing to AppImage | Routes to AppImage extraction instead of raw direct-binary installation. |

### Installation Flow Tests

| ID | Platform | Scenario | Expected result |
| --- | --- | --- | --- |
| `INSTALL-001` | both | Tool already available and version command succeeds. | Status is `Present`; install branch is not called. |
| `INSTALL-002` | both | Tool already available and version command fails. | Install branch is called; detail includes existing version failure. |
| `INSTALL-003` | both | Tool absent and install succeeds. | Status is `Installed`; marker is written; version is reported. |
| `INSTALL-004` | both | Tool absent and installer command fails. | Status is `Failed`; final exit is nonzero. |
| `INSTALL-005` | both | Install succeeds but command remains unavailable. | Status is `Missing`; final exit is nonzero. |
| `INSTALL-006` | both | Install succeeds but version command fails afterward. | Status is `Failed`; final exit is nonzero. |
| `INSTALL-007` | both | Platform installer is unavailable. | Status is `Skipped`; final exit stays zero when no failure exists. |
| `INSTALL-008` | both | Dry-run with a supported installer. | Status is `DryRun`; no command, download, marker, or path write occurs. |
| `INSTALL-009` | both | Dry-run with an unavailable installer. | Status is `Skipped`; no state changes occur. |
| `INSTALL-010` | both | Verbose install path. | Debug output includes installer kind and resolved paths without changing behavior. |

### Prefix and Path Tests

| ID | Platform | Scenario | Expected result |
| --- | --- | --- | --- |
| `PATH-001` | windows | No prefix. | Uses `%LOCALAPPDATA%\CodingAgentToolchain` and shared `bin` command shims. |
| `PATH-002` | linux | No prefix with unset or relative `XDG_DATA_HOME`. | Uses `$HOME/.local/share/coding-agent-toolchain/tools/linux-<machine>`. |
| `PATH-003` | linux | No prefix with absolute `XDG_DATA_HOME` inside `HOME`. | Uses that data root for managed payloads. |
| `PATH-004` | both | Valid absolute prefix inside user root. | Uses `<prefix>/coding-agent-toolchain` or `<prefix>\coding-agent-toolchain`. |
| `PATH-005` | both | Valid relative prefix resolving inside user root. | Prefix is accepted after normalization. |
| `PATH-006` | both | Prefix equal to user root. | Prefix is accepted and tool payloads stay under `coding-agent-toolchain`. |
| `PATH-007` | both | Prefix outside user root. | Exit nonzero with the documented user-scoped prefix error. |
| `PATH-008` | windows | Existing WindowsApps alias for a command. | Alias is ignored and does not satisfy availability. |
| `PATH-009` | linux | Windows interop command path. | Interop command is ignored and does not satisfy availability. |
| `PATH-010` | windows | Published command shim absent, managed, unmanaged. | Managed shim can be created or replaced; unmanaged file blocks replacement. |
| `PATH-011` | linux | Published command symlink absent, managed, unmanaged. | Managed symlink can be created or replaced; unmanaged link or file blocks replacement. |
| `PATH-012` | both | `--check-path` when directory is in `PATH`. | Path status is `InPath`. |
| `PATH-013` | both | `--check-path` when directory is not in `PATH`. | Path status is `Missing`. |
| `PATH-014` | both | `--check-path` for skipped, dry-run, or unresolved directory. | Status is `Skipped`, `Simulated`, or `NotResolved` as appropriate. |
| `PATH-015` | both | Prefix path is syntactically invalid for the platform. | Exit nonzero with an invalid-prefix diagnostic before any directory, marker, command shim, symlink, profile, or PATH write. |
| `PATH-016` | both | Prefix path does not exist and must not be implicitly created by validation. | Exit nonzero with an invalid-prefix or missing-prefix-target diagnostic before any state change. |
| `PATH-017` | both | Prefix path cannot be created, resolved, or accessed because of permissions, read-only media, reserved names, or missing parent directories. | Exit nonzero with an invalid-prefix diagnostic before any state change. |
| `PATH-018` | both | Prefix path is a symlink, junction, or equivalent path that appears under the user root but resolves outside it. | Exit nonzero and no outside-user-root target is created, modified, or removed. |
| `PATH-019` | both | System directory or absolute `XDG_DATA_HOME` outside `HOME` is supplied through prefix, environment-derived default root, command publication path, or installer output path. | Exit nonzero and no outside-user-root content is created, modified, or removed. |

### Removal Safety Tests

| ID | Platform | Scenario | Expected result |
| --- | --- | --- | --- |
| `REMOVE-001` | both | Remove as administrator or root. | Exit nonzero and no removal occurs. |
| `REMOVE-002` | both | Missing user profile or `HOME`. | Exit nonzero and no removal occurs. |
| `REMOVE-003` | both | Supported tool with marker inside user root. | Tool directory is removed and status is `Removed`. |
| `REMOVE-004` | both | Missing marker. | Tool is skipped with marker-missing detail. |
| `REMOVE-005` | both | Target directory missing. | Tool is skipped with directory-missing detail. |
| `REMOVE-006` | both | Target is user root or profile root. | Removal is refused. |
| `REMOVE-007` | both | Target is a shared toolchain directory. | Removal is refused. |
| `REMOVE-008` | both | Target is outside user root. | Removal is refused. |
| `REMOVE-009` | windows | Managed command shim points into removed directory. | Matching shim is removed after payload removal. |
| `REMOVE-010` | linux | Managed command symlink points into removed directory. | Matching symlink is removed after payload removal. |
| `REMOVE-011` | both | Published command does not point into removed directory. | Command entry is left untouched. |
| `REMOVE-012` | both | Dry-run remove. | Status is `DryRun`; no file or command entry is removed. |
| `REMOVE-013` | both | Obsolete persistent `PATH` entry remains after removal. | Summary lists the obsolete entry and exits nonzero. |
| `REMOVE-014` | both | Unsupported platform installer in remove mode. | Status is `Skipped`; no removal is attempted. |
| `REMOVE-015` | windows | PowerShell `-WhatIf` removal. | Removal is not confirmed and status is `Skipped`. |

### Archive and Release Asset Tests

| ID | Platform | Scenario | Expected result |
| --- | --- | --- | --- |
| `ARCHIVE-001` | both | `zip` archive with expected executable at root. | Executable is copied or extracted and made runnable. |
| `ARCHIVE-002` | both | `zip` archive with `archive_path`. | The configured path is used. |
| `ARCHIVE-003` | linux | `tar.gz` archive with expected executable. | Executable is extracted and made runnable. |
| `ARCHIVE-004` | linux | `tar.xz` archive with expected executable. | Executable is extracted and made runnable. |
| `ARCHIVE-005` | windows | `seven_zip` portable archive. | Archive is extracted using the configured Windows archive path. |
| `ARCHIVE-006` | linux | AppImage extraction success. | Extracted command is published. |
| `ARCHIVE-007` | both | Archive missing expected executable. | Tool result is `Failed` with missing-command detail. |
| `ARCHIVE-008` | both | GitHub release has no matching asset. | Tool result is `Failed` with no-matching-asset detail. |
| `ARCHIVE-009` | both | Download command fails. | Tool result is `Failed` and no marker is written. |

### Canonical Manifest Coverage Tests

In this table, `unavailable` means the canonical manifest omits that platform's
installer block and the platform script skips the tool.

| ID | Tool | Windows kind | Linux kind | Required direct coverage |
| --- | --- | --- | --- | --- |
| `TOOL-001` | `yamllint` | `pip` | `pip` | `DISPATCH-001`, `INSTALL-001` through `INSTALL-009` |
| `TOOL-002` | `yq` | `direct_binary` | `direct_binary` | `DISPATCH-009`, `ARCHIVE-009` |
| `TOOL-003` | `jq` | `direct_binary` | `direct_binary` | `DISPATCH-009`, `ARCHIVE-009` |
| `TOOL-004` | `shfmt` | `direct_binary` | `direct_binary` | `DISPATCH-009`, `ARCHIVE-009` |
| `TOOL-005` | `markdownlint-cli2` | `npm_global` | `npm_global` | `DISPATCH-004` |
| `TOOL-006` | `commitlint` | `npm_global` | `npm_global` | `DISPATCH-004` |
| `TOOL-007` | `imagemagick` | `portable_archive` | `appimage_extract` | `DISPATCH-011`, `DISPATCH-013`, `ARCHIVE-005`, `ARCHIVE-006` |
| `TOOL-008` | `ghostscript` | `direct_installer` | `source_make` | `DISPATCH-012`, `DISPATCH-014`, `DISPATCH-015` |
| `TOOL-009` | `shellcheck` | `direct_binary` | `direct_binary` | `DISPATCH-009`, `ARCHIVE-001` through `ARCHIVE-004` |
| `TOOL-010` | `sqlfluff` | `pip` | `pip` | `DISPATCH-001` |
| `TOOL-011` | `pre-commit` | `pip` | `pip` | `DISPATCH-001` |
| `TOOL-012` | `gitleaks` | `github_release_asset` | `github_release_asset` | `DISPATCH-010`, `ARCHIVE-001`, `ARCHIVE-003`, `ARCHIVE-008` |
| `TOOL-013` | `betterleaks` | `github_release_asset` | `github_release_asset` | `DISPATCH-010`, `ARCHIVE-001`, `ARCHIVE-003`, `ARCHIVE-008` |
| `TOOL-014` | `github-cli` | `github_release_asset` | `github_release_asset` | `DISPATCH-010`, `ARCHIVE-001`, `ARCHIVE-003`, `ARCHIVE-008` |
| `TOOL-015` | `tsx` | `npm_global` | `npm_global` | `DISPATCH-004` |
| `TOOL-016` | `local-action` | `npm_global` | `npm_global` | `DISPATCH-004`, `MANIFEST-016` |
| `TOOL-017` | `ruff` | `pip` | `pip` | `DISPATCH-001` |
| `TOOL-018` | `editorconfig-checker` | `github_release_asset` | `github_release_asset` | `DISPATCH-010`, `ARCHIVE-001`, `ARCHIVE-003`, `ARCHIVE-008` |
| `TOOL-019` | `psscriptanalyzer` | `powershell_gallery` | `powershell_gallery` | `DISPATCH-005` |
| `TOOL-020` | `bats-core` | `unavailable` | `npm_global` | `MANIFEST-009`, `INSTALL-007`, `DISPATCH-004` |
| `TOOL-021` | `pester` | `powershell_gallery` | `powershell_gallery` | `DISPATCH-005` |
| `TOOL-022` | `codespell` | `pip` | `pip` | `DISPATCH-001` |
| `TOOL-023` | `actions-runner` | `portable_archive` | `portable_archive` | `DISPATCH-011`, `ARCHIVE-003` |
| `TOOL-024` | `actionlint` | `github_release_asset` | `github_release_asset` | `DISPATCH-010`, `ARCHIVE-001`, `ARCHIVE-003`, `ARCHIVE-008` |

### Documentation Consistency Tests

| ID | Scenario | Expected result |
| --- | --- | --- |
| `DOC-001` | Compare README option list with both script parsers. | Every documented option is accepted by both scripts. |
| `DOC-002` | Compare README installer-kind list with manifest and dispatch branches. | Every documented kind is either dispatched or covered by unsupported-kind tests. |
| `DOC-003` | Compare README default directory tables with path-resolution tests. | Each documented default directory has direct coverage. |
| `DOC-004` | Compare README removal safety claims with removal tests. | Each safety claim has direct coverage. |
| `DOC-005` | Compare README installed-tool list with canonical manifest. | Tool names and executables remain aligned. |

## Equivalence Rules

Use these equivalence rules to keep the suite minimal while preserving complete
combination accounting.

- Short and long option spellings are equivalent only after `CLI-003`,
  `CLI-005`, `CLI-007`, `CLI-009`, and `CLI-010` prove both spellings.
- Different tool IDs with the same installer kind are equivalent for dispatch
  only after the canonical manifest coverage table proves every tool maps to a
  tested kind.
- Windows and Linux are never equivalent for path, prefix, publication, or
  removal behavior.
- Dry-run and non-dry-run branches are never equivalent for filesystem, profile,
  network, package manager, marker, or removal effects.
- `--check-path` rows are equivalent only within the same final tool status:
  `Present`, `Installed`, `DryRun`, `Skipped`, `Missing`, or `Failed`.
- Missing required installer fields are equivalent only when they fail through
  the same required-field helper and name the missing field.
- Archive formats are not equivalent unless the same extraction function and
  expected executable resolution path are used.
- Unavailable platform installer rows are equivalent only after
  `MANIFEST-009`, `MANIFEST-010`, `INSTALL-007`, and `REMOVE-014` pass.
- New hardening rows must not replace existing rows. If a new row resembles an
  existing one, it must name the additional failure condition it proves, such as
  unreadable config, non-YAML config, impossible prefix, elevated identity, or
  filesystem-boundary refusal.
- Missing, unreadable, non-YAML, and malformed YAML config paths are not
  equivalent unless they fail through the same validation branch and produce the
  same diagnostic class.
- Outside-user-root, system-directory, nonexistent, syntactically invalid, and
  uncreatable prefixes are not equivalent unless they fail through the same
  validation branch and prove the same no-side-effect invariant.
- Root or administrator rejection is not equivalent to removal-only elevation
  rejection; it must be tested for each public mode listed in `SAFETY-001` and
  `SAFETY-002`.

## Fixture Requirements

- Run tests with temporary user roots and temporary `PATH` values.
- On Windows, redirect `LOCALAPPDATA`, user `Path`, package-manager commands,
  and any test prefix to isolated temporary locations where practical.
- On Linux, redirect `HOME`, `.profile`, `PATH`, and any test prefix to
  isolated temporary locations. Keep `XDG_DATA_HOME` under `HOME` except when
  a test intentionally validates the outside-root refusal path.
- Provide fake commands for package managers and external tools, including
  `python`, `pip`, `npm`, `pwsh`, `brew`, `winget`, `choco`, `curl`, `gh`,
  `tar`, and `make`, according to the branch under test.
- Provide synthetic archives and release metadata locally for routine archive
  and release tests.
- Create `.coding-agent-toolchain` markers only inside temporary directories.
- Assert both positive effects and negative effects, especially that dry-run and
  refused-removal cases leave files, profiles, and command entries unchanged.
- For filesystem-boundary tests, create before-and-after snapshots of every
  candidate path, including system directories, outside-user-root directories,
  temporary user roots, profile files, command publication directories, marker
  locations, download directories, and archive extraction directories.
- For config error tests, provide distinct fixtures for missing, unreadable,
  non-YAML, and malformed YAML files so the runner cannot satisfy multiple cases
  with one ambiguous fixture.
- For prefix error tests, provide distinct fixtures for outside-user-root,
  nonexistent, syntactically invalid, and uncreatable paths so each diagnostic
  and no-side-effect assertion is independently checkable.

## Optional Network Smoke Tests

Network smoke tests are outside the routine gate. Run them only on disposable
machines or containers, with an isolated user profile and explicit approval for
network access.

| ID | Platform | Scenario | Expected result |
| --- | --- | --- | --- |
| `SMOKE-001` | windows | Run dry-run with canonical manifest. | All canonical tools are simulated without changes. |
| `SMOKE-002` | linux | Run dry-run with canonical manifest. | All canonical tools are simulated without changes. |
| `SMOKE-003` | windows | Install one small package-backed tool into a temporary prefix. | Tool installs, version is reported, marker is written, removal succeeds. |
| `SMOKE-004` | linux | Install one small package-backed tool into a temporary prefix. | Tool installs, version is reported, marker is written, removal succeeds. |

## Verification Commands

Run the repository checks below before accepting test-plan or test-suite
changes.

```powershell
markdownlint-cli2 "**/*.md"
yamllint .yamllint .markdownlint-cli2.yaml config/tools.yaml .github/workflows/validation.yml .github/dependabot.yml
actionlint .github/workflows/validation.yml
editorconfig-checker .
.\tests\test-plan.ps1
```

When shell scripts change, also run:

```powershell
bash -n scripts/install-tools.sh
shfmt -d -i 2 scripts/install-tools.sh
shellcheck scripts/install-tools.sh
```

When PowerShell scripts change, also run:

```powershell
$scriptPaths = @(
    ".\scripts\install-tools.ps1",
    ".\tests\test-plan.ps1",
    ".\tests\generate-combination-inventory.ps1"
)

foreach ($scriptPath in $scriptPaths) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path $scriptPath),
        [ref] $tokens,
        [ref] $errors
    ) > $null
    if ($errors) {
        $errors
        exit 1
    }
}

foreach ($scriptPath in $scriptPaths) {
    Invoke-ScriptAnalyzer -Path $scriptPath
}
```

For test-plan-only changes, the script checks are still useful as confidence
checks because this document references script behavior. Report any unavailable
command and the fallback that was used.
