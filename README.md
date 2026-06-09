# Coding Agent Toolchain

Coding Agent Toolchain installs user-scoped validation tools for agent-assisted
software development on Windows and Linux. It reads a declarative YAML manifest,
checks whether each target program is available, installs missing tools with
approved installer types, and reports the exact versions found after execution.

## Installation

Clone this repository and run the platform script from the repository root.
Installations are scoped to the current user and must not require system-wide
changes.

## Usage

On Windows:

```powershell
.\scripts\install-tools.ps1 -c .\config\tools.yaml
```

On Linux:

```bash
./scripts/install-tools.sh -c ./config/tools.yaml
```

Both scripts use `config/tools.yaml` by default.

Use `-v` or `--verbose` to print detailed execution traces. The PowerShell
script also honors PowerShell's native `-Verbose` common parameter.
Use `-d` or `--dry-run` to simulate a successful run without modifying files,
profiles, `PATH`, or installed packages.
Use `-c <path>` or `--config <path>` to read a custom YAML manifest.
Use `-p <directory>` or `--prefix <directory>` to install missing tools under
`<directory>/coding-agent-toolchain/<tool>/`. The prefix must stay inside the
current user's profile or home directory.
Use `--check-path` to verify and print whether resolved tool directories are
available in the current user's `PATH`.
Use `-r` or `--remove` to remove tools that were installed by Coding Agent
Toolchain.
Use `-h` or `--help` to print the script version and help.

## Features

- Checks and installs these validation tools: `yamllint`, `shfmt`,
  `markdownlint`, ImageMagick, Ghostscript, `shellcheck`, `sqlfluff`,
  GitHub CLI, `ruff`, and PSScriptAnalyzer.
- Supports declarative installer kinds for `winget`, `npm`, Chocolatey,
  `brew`, `pip`, PowerShell Gallery modules, conda-forge packages through
  user-scoped micromamba, direct binaries, portable archives, extracted
  AppImages, GitHub release assets, and user-prefix source builds.
- Supports a custom user-scoped installation prefix for missing tools.
- Keeps installation state under the current user profile and updates only the
  current user's `PATH`.
- Builds Ghostscript from source when a C compiler is available on Linux, then
  falls back to conda-forge through user-scoped micromamba when it is not.
- Supports dry runs that simulate successful execution without making changes.
- Prints visible progress for each major action, with detailed traces when
  verbose output is enabled.
- Runs each configured version command and prints the exact version output in
  the final summary.
- Optionally verifies resolved tool directories in the current user's `PATH`.
- Reports missing tools, failed installations, and failed version checks.
- Removes only tool directories that contain the `.coding-agent-toolchain`
  marker created during installation.

Chocolatey support is available for manifests that need it, but package
behavior depends on each Chocolatey package. Packages that cannot honor a
user-scoped installation are reported as installation failures.

Installing PSScriptAnalyzer on Linux requires a usable `pwsh` command because
PowerShell Gallery modules are installed through PowerShell.

## Removal Safety

Removal mode is intentionally conservative. Coding Agent Toolchain writes a
`.coding-agent-toolchain` marker in each tool directory it creates. The marker
contains the installation timestamp and user name.

When `-r` or `--remove` is used, a tool directory is removed only when all of
these conditions are true:

- the directory is inside the current user's profile or home directory;
- the directory contains the `.coding-agent-toolchain` marker;
- the directory can be identified as a Coding Agent Toolchain installation.

Directories without this marker are never emptied or removed. When a directory
is skipped, the removal summary reports the reason in the `Version` column.

## Installed Tools

| Program | Source repository |
| --- | --- |
| `yamllint` | [adrienverge/yamllint](https://github.com/adrienverge/yamllint) |
| `shfmt` | [patrickvane/shfmt](https://github.com/patrickvane/shfmt) |
| `markdownlint` | [DavidAnson/markdownlint](https://github.com/DavidAnson/markdownlint) |
| ImageMagick | [ImageMagick/ImageMagick](https://github.com/ImageMagick/ImageMagick) |
| Ghostscript | [ArtifexSoftware/ghostpdl](https://github.com/ArtifexSoftware/ghostpdl) |
| `shellcheck` | [koalaman/shellcheck](https://github.com/koalaman/shellcheck) |
| `sqlfluff` | [sqlfluff/sqlfluff](https://github.com/sqlfluff/sqlfluff) |
| GitHub CLI | [cli/cli](https://github.com/cli/cli) |
| `ruff` | [astral-sh/ruff](https://github.com/astral-sh/ruff) |
| PSScriptAnalyzer | [PowerShell/PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) |

## Configuration

The tool list is stored in `config/tools.yaml`. The manifest is declarative:
entries select supported installer kinds instead of embedding arbitrary shell
commands.

## Verification

Each installed program is checked with its configured version command. The final
output includes a summary of all tools and the exact version output reported by
each program.

For repository changes, run the documentation and manifest checks before
committing:

```powershell
markdownlint-cli2 "**/*.md"
yamllint .yamllint .markdownlint-cli2.yaml config/tools.yaml
```

## Contributing

Before committing, configure the repository commit template if you want Git to
load it automatically:

```powershell
git config commit.template .gitmessage
```

## License

[MIT](LICENSE.txt)
