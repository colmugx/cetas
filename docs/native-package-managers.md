# Cetas Native installation and package-manager publishing

**Cetas JS via npm remains the recommended terminal.** Native is an optional Go/Bubble Tea alternative; Homebrew and Scoop install the full Native bundle with its ACP and Run siblings. Standalone `cetas-acp-*` and `cetas-run-*` downloads remain available for editor integration and one-off scripts.

## For users

macOS Apple Silicon or Linux x64:

```sh
brew install colmugx/tap/cetas
brew upgrade cetas
```

Windows x64:

```powershell
scoop bucket add cetas https://github.com/colmugx/scoop-bucket
scoop install cetas/cetas
scoop update cetas
```

The native [install.sh](../install.sh) and [install.ps1](../install.ps1) are alternative interactive installers, not hooks run by the package managers. Both show the version, destination, and file list before requesting confirmation. For unmanaged direct downloads use [Cetas GitHub Releases](https://github.com/colmugx/cetas/releases) (choose `cetas-v*` rather than the separate Memoh series). Windows must keep `cetas_moon.dll` adjacent to `cetas.exe`.

Homebrew and npm may both expose `cetas`; the first executable found on `PATH` wins. Check `command -v cetas` or `Get-Command cetas`.

## For maintainers

This independent, manually dispatched workflow mirrors `.github/workflows/npm-publish.yml`.
**One run updates both package managers**, with no OS matrix or binary rebuild.

## One-time publisher setup

1. Create the public repositories `colmugx/homebrew-tap` and `colmugx/scoop-bucket`,
   each initialized with the default `main` branch.
2. Set `PACKAGE_REPOS_TOKEN` under the `cetas` repository's Actions secrets:
   a fine-grained GitHub PAT with **Contents: read/write** on both target
   repositories. The default `GITHUB_TOKEN` cannot write to them.
3. In GitHub Actions, choose **cetas package managers publish**, select `main`,
   enter an existing stable tag (e.g. `cetas-v0.11.2`), and run it.

The job validates that the GitHub Release contains all seven required files,
reads their SHA256 digests from its `SHA256SUMS`, and updates:

- `homebrew-tap/Formula/cetas.rb`
- `scoop-bucket/bucket/cetas.json`

It rejects incomplete or prerelease assets and version downgrades. Retrying
a successful release is idempotent. GitHub cannot atomically push to two
independent repositories; retrying after a partial push is supported.

## Package contents and upgrade commands

macOS arm64 and Linux x64:

```sh
brew install colmugx/tap/cetas
brew upgrade cetas
```

Windows x64:

```powershell
scoop bucket add cetas https://github.com/colmugx/scoop-bucket
scoop install cetas/cetas
scoop update cetas
```

Homebrew downloads the **three individual Unix archives** as resources.
Windows Scoop installs the **existing full** `cetas-windows-x64.zip`,
keeping `cetas_moon.dll` adjacent to the executables.

The original `cetas-acp-{platform}` and `cetas-run-{platform}` assets
remain available for Lody and one-off runs. Neither this workflow nor the
manifest generator modifies `.github/workflows/release.yml`.

A future optional all-in-one Unix archive would be additional to, not a
replacement for, the individual downloads.
