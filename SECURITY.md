# Security Policy

## Supported Versions

Security fixes target the default branch and the latest tagged release unless a
release note states otherwise.

## Installer Supply Chain Trust Boundary

Installers declared in `config/tools.yaml` may resolve moving upstream sources,
including package-manager channels, `latest` or `stable` labels, GitHub release
assets, direct URLs, and source build fallbacks. The installer scripts do not
currently pin those upstream artifacts with checksums or signatures.

The local test plan still requires each canonical installer kind to declare a
verification strategy. The `trusted_upstream` strategy records an explicit
trust decision for moving sources until checksum or signature verification is
implemented for that kind.

This is an accepted bootstrapping risk for the current repository scope, not a
guarantee that upstream artifacts are stable or authenticated. Track
remediation through the installer verification strategy table and update the
manifest schema plus installer enforcement before marking any kind as
`checksum` or `signature`.

Treat the manifest sources and the upstream package managers or release assets
they reference as trusted inputs before running an install. This boundary is
separate from the GitHub Actions validation workflow trust boundary documented
in `README.md`; CI dependency choices do not make installer downloads
reproducible or verified.

## Reporting a Vulnerability

Use GitHub private vulnerability reporting when it is available for this
repository. If that option is not available, open a public issue that requests a
private contact path and do not include exploit details, secrets, or sensitive
environment information.

Include the affected version or commit, operating system, installation mode, and
a minimal description of the suspected impact. Do not run destructive validation
against systems you do not own or have permission to test.
