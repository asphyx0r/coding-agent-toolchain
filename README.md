# Coding Agent Toolchain

Coding Agent Toolchain installs user-scoped validation tools for agent-assisted
software development on Windows and Linux. It reads a declarative YAML manifest,
checks whether each target program is available, installs missing tools with
approved installer types, and reports the exact versions found after execution.

## Prerequisites

- Windows: Windows PowerShell or PowerShell, with permission to write under the
  current user's profile.
- Linux: Bash, with permission to write under the current user's home directory.
- Missing tools require network access to the installer sources declared in
  `config/tools.yaml`.
- Installer kinds may require their matching platform commands when selected,
  such as `winget`, `choco`, `brew`, `pwsh`, `python`, `npm`, or a C compiler
  for Linux source builds.

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

Supported arguments:

- `-v`, `--verbose`: prints detailed execution traces. The PowerShell script
  also honors PowerShell's native `-Verbose` common parameter.
- `-d`, `--dry-run`: simulates a successful run without modifying files,
  profiles, `PATH`, or installed packages.
- `-c <path>`, `--config <path>`: reads a custom YAML manifest.
- `-p <directory>`, `--prefix <directory>`: installs missing tools under
  `<directory>/coding-agent-toolchain/<tool>/`. The prefix directory must
  already exist, stay inside the current user's profile or home directory, and
  overrides all default installation directories used by the selected platform
  script.
- `--check-path`: verifies and prints whether resolved tool directories are
  available in the current user's `PATH`.
- `-r`, `--remove`: removes tools that were installed by Coding Agent Toolchain.
- `-h`, `--help`: prints the script version and help.

## Default Directories

### Windows

When `scripts/install-tools.ps1` runs without `--prefix`, it uses the current
user's local application data directory for managed payloads and exposes only
command shims through a stable command directory.

The default managed payload root is:

```text
%LOCALAPPDATA%\CodingAgentToolchain\
```

| Purpose | Default Windows location |
| --- | --- |
| Tool payloads | `%LOCALAPPDATA%\CodingAgentToolchain\<tool>\` |
| Tool commands inside payloads | `<tool>\bin\<command>` or `<tool>\Scripts\<command>` |
| Commands on `PATH` | `%LOCALAPPDATA%\CodingAgentToolchain\bin\<command>.cmd` shims |
| Installation marker | `<tool>\.coding-agent-toolchain` |
| Managed npm prefix | `%LOCALAPPDATA%\CodingAgentToolchain\<tool>\` |
| Managed Chocolatey root | `%LOCALAPPDATA%\CodingAgentToolchain\chocolatey\` |

This keeps downloaded binaries, npm packages, Python virtual environments, and
other tool payloads isolated by tool name. The shared `bin` directory contains
only command shims created by Coding Agent Toolchain, so removal mode can delete
marked per-tool payload directories and their matching command shims without
emptying or removing the shared command directory.

Passing `--prefix <directory>` changes the root used for these defaults to
`<directory>\coding-agent-toolchain\`. For example, tool payloads then use
`<directory>\coding-agent-toolchain\<tool>\`, and command discovery uses
prefix-scoped command locations under each tool payload instead of the shared
shim directory.

### Linux

When `scripts/install-tools.sh` runs without `--prefix`, it uses an
XDG-compatible user data root for managed payloads and exposes only command
links through the user command directory.

The default managed payload root is:

```text
${XDG_DATA_HOME:-$HOME/.local/share}/coding-agent-toolchain/tools/linux-<machine>/
```

`<machine>` is the value reported by `uname -m`, such as `x86_64`. If
`XDG_DATA_HOME` is unset, empty, or relative, the script uses
`$HOME/.local/share`. If `XDG_DATA_HOME` is absolute, it must resolve inside
the current user's `$HOME`; absolute paths outside `$HOME` are rejected to
preserve the user-scoped installation boundary.

| Purpose | Default Linux location |
| --- | --- |
| Tool payloads | `${XDG_DATA_HOME:-$HOME/.local/share}/coding-agent-toolchain/tools/linux-<machine>/<tool>/` |
| Tool commands inside payloads | `<tool>/bin/<command>` |
| Commands on `PATH` | `$HOME/.local/bin/<command>` symlinks |
| Installation marker | `<tool>/.coding-agent-toolchain` |
| Managed Node.js runtime | `coding-agent-toolchain/tools/linux-<machine>/node/` |
| Managed micromamba runtime | `coding-agent-toolchain/tools/linux-<machine>/micromamba/` |
| Managed micromamba root | `coding-agent-toolchain/tools/linux-<machine>/micromamba-root/` |

This keeps architecture-specific binaries under the toolchain-managed data
tree, while `~/.local/bin` contains only stable entry points. Removal mode can
therefore delete marked per-tool payload directories and their matching command
links without emptying or removing the shared `~/.local/bin` directory.

This default layout is compatible with the
[XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/latest/)
and the
[Filesystem Hierarchy Standard 3.0](https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html).
The XDG specification defines `$XDG_DATA_HOME` for user-specific data files,
defaults it to `$HOME/.local/share`, requires XDG environment paths to be
absolute, and allows user-specific executables in `$HOME/.local/bin`. The FHS
treats `/home` as site-specific, recognizes XDG-style home-directory layouts,
and reserves `/usr/local` for software installed locally by the system
administrator, so the Linux script avoids system-wide default locations.

Passing `--prefix <directory>` changes the root used for these defaults to
`<directory>/coding-agent-toolchain/`. For example, tool payloads then use
`<directory>/coding-agent-toolchain/<tool>/`, and command links use the matching
`bin/` directory under that prefix.

## Features

- Checks and installs these validation tools where supported on the target
  platform: `yamllint`, `shfmt`, `yq`, `jq`, `markdownlint-cli2`, `commitlint`,
  ImageMagick, Ghostscript, `shellcheck`, `sqlfluff`, `pre-commit`, Gitleaks,
  `betterleaks`, GitHub CLI, `tsx`, `local-action`, GitHub Actions Runner,
  `actionlint`, `ruff`, `editorconfig-checker`, PSScriptAnalyzer, `bats-core`,
  Pester, and `codespell`.
- Supports declarative installer kinds for `winget`, `npm`, Chocolatey,
  `brew`, `pip`, PowerShell Gallery modules, conda-forge packages through
  user-scoped micromamba, direct binaries, portable archives, extracted
  AppImages, GitHub release assets, and user-prefix source builds.
- Supports a custom user-scoped installation prefix for missing tools.
- Keeps installation state under the current user profile, or the Linux XDG
  data root when configured, and updates only the current user's `PATH`.
- Builds Ghostscript from source when a C compiler is available on Linux, then
  falls back to conda-forge through user-scoped micromamba when it is not.
- Supports dry runs that simulate successful execution without making changes.
- Prints visible progress for each major action, with detailed traces when
  verbose output is enabled. Log prefixes use padded log4j-style levels such
  as `[INFO ]`, `[WARN ]`, `[ERROR]`, and `[DEBUG]`.
- Runs each configured version command, or an availability check for tools
  without a safe version command, and prints the detected value in the final
  summary.
- Optionally verifies resolved tool directories in the current user's `PATH`.
- Reports missing tools, failed installations, and failed verification checks.
- Removes only tool directories that contain the `.coding-agent-toolchain`
  marker created during installation.

Chocolatey support is available for manifests that need it, but package
behavior depends on each Chocolatey package. Packages that cannot honor a
user-scoped installation are reported as installation failures.

Installing PowerShell Gallery modules on Linux, such as PSScriptAnalyzer and
Pester, requires a usable `pwsh` command because PowerShell Gallery modules are
installed through PowerShell. When `pwsh` is not available or not usable, the
Linux script reports those tools as skipped instead of failing the full run.

`bats-core` is configured only for Linux. On Windows, the manifest omits the
`bats-core` Windows installer so the Windows script reports it as skipped.

## Removal Safety

Removal mode is intentionally conservative. Coding Agent Toolchain writes a
`.coding-agent-toolchain` marker in each tool directory it creates. The marker
contains the installation timestamp and user name.

When `-r` or `--remove` is used, a tool directory is removed only when all of
these conditions are true:

- the directory is inside the current user's profile, home directory, or Linux
  XDG data root;
- the directory contains the `.coding-agent-toolchain` marker;
- the directory can be identified as a Coding Agent Toolchain installation.

Directories without this marker are never emptied or removed. When a directory
is skipped, the removal summary reports the reason in the `Version` column.

## Installed Tools

The list below points to each upstream project. Installation sources are defined
in `config/tools.yaml` and can use a separate release repository or direct
download URL.

- `yamllint`: [yamllint project](https://github.com/adrienverge/yamllint)
- `yq`: [yq project](https://github.com/mikefarah/yq)
- `jq`: [jq project](https://github.com/jqlang/jq)
- `shfmt`: [shfmt project](https://github.com/patrickvane/shfmt)
- `markdownlint-cli2`: [markdownlint-cli2 project](https://github.com/DavidAnson/markdownlint-cli2)
- `commitlint`: [commitlint project](https://github.com/conventional-changelog/commitlint)
- ImageMagick: [ImageMagick project](https://github.com/ImageMagick/ImageMagick)
- Ghostscript: [Ghostscript project](https://github.com/ArtifexSoftware/ghostpdl)
- `shellcheck`: [ShellCheck project](https://github.com/koalaman/shellcheck)
- `sqlfluff`: [SQLFluff project](https://github.com/sqlfluff/sqlfluff)
- `pre-commit`: [pre-commit project](https://github.com/pre-commit/pre-commit)
- Gitleaks: [Gitleaks project](https://github.com/gitleaks/gitleaks)
- `betterleaks`: [betterleaks project](https://github.com/betterleaks/betterleaks)
- GitHub CLI: [GitHub CLI project](https://github.com/cli/cli)
- `tsx`: [tsx project](https://github.com/privatenumber/tsx)
- `local-action`: [GitHub local-action project](https://github.com/github/local-action)
- GitHub Actions Runner: [actions/runner project](https://github.com/actions/runner)
- `actionlint`: [actionlint project](https://github.com/rhysd/actionlint)
- `ruff`: [Ruff project](https://github.com/astral-sh/ruff)
- `editorconfig-checker`: [editorconfig-checker project](https://github.com/editorconfig-checker/editorconfig-checker)
- PSScriptAnalyzer: [PSScriptAnalyzer project](https://github.com/PowerShell/PSScriptAnalyzer)
- `bats-core`: [bats-core project](https://github.com/bats-core/bats-core)
- Pester: [Pester project](https://github.com/pester/Pester)
- `codespell`: [codespell project](https://github.com/codespell-project/codespell)

## Configuration

The tool list is stored in `config/tools.yaml`, which is the canonical source
for installed tools. The manifest is declarative: entries select supported
installer kinds instead of embedding arbitrary shell commands.

The manifest schema is intentionally small:

- `schema_version` must be `1`.
- `tools` is an ordered list of tool definitions.
- each tool in the canonical manifest defines `id`, `executable`, and
  `installers`.
- `version_check` defaults to `command`. Set it to `command_available` for
  tools that should be verified by executable availability only.
- `version_args` defines the executable arguments used for version checks when
  the installer does not have a dedicated version lookup.
- `installers` can define `windows` and `linux` blocks. Each platform block
  uses a `kind` plus the fields required by that installer kind. A missing
  platform block is treated as unavailable and reported as skipped by that
  platform script.

Supported installer kinds are `winget`, `npm_global`, `chocolatey`, `brew`,
`pip`, `python_user`, `uv_tool`, `powershell_gallery`, `conda_forge`,
`direct_binary`, `portable_archive`, `appimage_extract`,
`github_release_asset`, `direct_installer`, and `source_make`.

Common installer fields include `package`, `url`, `owner`, `repo`,
`asset_pattern`, `file_name`, `archive_kind`, `archive_path`, `executable`,
`install_dir_name`, `bin_path`, `source_dir`, `install_args`, and
`target_arg_prefix`. Unsupported installer keys are rejected by the scripts.

The manifest intentionally uses current upstream sources for some installers,
including `latest`, `stable`, and latest GitHub release assets. This project
optimizes for bootstrapping current validation tools, not for reproducible
pinned tool versions.

These moving upstream sources are an explicit bootstrapping trust boundary. The
project does not currently verify downloaded checksums or signatures, so users
should treat upstream package managers, release assets, and direct download URLs
as trusted inputs when running the installers.

## Verification

Each installed program is checked with its configured version command, or by
executable availability when `version_check: command_available` is set. The
final output includes a summary of all tools and the detected version or
availability value for each program.

For repository changes, run the documentation and manifest checks before
committing:

```powershell
markdownlint-cli2 "**/*.md"
yamllint .yamllint .markdownlint-cli2.yaml config/tools.yaml .github/workflows/validation.yml
actionlint .github/workflows/validation.yml
.\tests\test-plan.ps1
```

The GitHub Actions validation workflow pins action references to full commit
SHAs with reviewed version comments, while installing current validation tools
from npm, pip, Go, Chocolatey, and PowerShell Gallery. Treat the installed
tool versions as a moving validation gate, not as a reproducible pinned release
build.

The complete repository test plan is documented in
[`TEST_PLAN.md`](TEST_PLAN.md). It defines the required CLI, manifest, installer,
path, removal, safety-boundary, and release-readiness coverage.

When scripts change, also run the script checks:

```powershell
bash -n scripts/install-tools.sh
shfmt -d -i 2 scripts/install-tools.sh
shellcheck scripts/install-tools.sh

$scriptPaths = @(
    ".\scripts\install-tools.ps1",
    ".\tests\test-plan.ps1"
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

## Security

See [SECURITY.md](SECURITY.md) for supported versions and vulnerability
reporting.

## Versioning

Scripts report `git describe --tags --long --always --dirty` when they run
from a Git checkout. If Git or `.git` metadata is unavailable, they fall back
to `v1.4.3`. `CHANGELOG.md` uses tag sections for release entries.

## Contributing

Use Conventional Commit headers for repository commits. Repository-level commit
message validation is defined in
[`commitlint.config.cjs`](commitlint.config.cjs). Check a candidate message with:

```powershell
"docs: align commit rules" | commitlint --config commitlint.config.cjs
```

Before committing, configure the repository commit template if you want Git to
load it automatically:

```powershell
git config commit.template .gitmessage
```

Example header:

```text
docs: align commit rules
```

## License

[MIT](LICENSE.txt)
