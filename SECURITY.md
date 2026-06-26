# Security Policy

## Supported Versions

Security fixes target the default branch and the latest tagged release unless a
release note states otherwise.

## Installer Supply Chain Trust Boundary

Installers declared in `config/tools.yaml` use schema `2` for canonical
direct artifacts. Those artifact entries pin fixed release URLs or
`release_tag` values and include SHA256 checksums that the Windows and Linux
installers verify immediately after download.

Package-manager channels such as `pip`, `npm_global`, `powershell_gallery`,
and `conda_forge`, plus the Linux bootstrap runtimes `linux_node_runtime` and
`linux_micromamba_runtime`, still rely on their upstream package managers or
runtime providers. The `trusted_upstream` strategy records that explicit trust
decision until a stronger verification model is added for that kind. This
boundary is deliberately floating: future installs can resolve newer upstream
package or runtime content without a repository change. Review package names,
upstream channels, and runtime sources periodically, especially before release
or manifest maintenance work.

Treat package managers as trusted inputs before running an install. Direct
release assets and direct download URLs in the canonical manifest are checksum
verified; that installer trust boundary remains separate from the GitHub
Actions validation workflow trust boundary documented in `README.md`.

## Reporting a Vulnerability

Use GitHub private vulnerability reporting when it is available for this
repository. If that option is not available, open a public issue that requests a
private contact path and do not include exploit details, secrets, or sensitive
environment information.

Include the affected version or commit, operating system, installation mode, and
a minimal description of the suspected impact. Do not run destructive validation
against systems you do not own or have permission to test.
