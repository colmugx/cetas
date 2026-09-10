---
title: Installation
description: Install or build the Cetas surfaces that the repository ships today.
---

Cetas does not currently document a package-manager or shell installer. Do not assume an install command that the repository does not provide.

## Release artifacts

Tagged releases publish prebuilt archives for **cetas-bun** and **cetas-acp** on:

- macOS arm64 (`darwin-arm64`)
- Linux x64 (`linux-x64`)
- Windows x64 (`windows-x64`)

The release also publishes `SHA256SUMS` for those archives.

Use the [latest GitHub Release](https://github.com/colmugx/cetas/releases/latest) to choose the artifact for your platform.

`cetas-headless` exists in the repository, but the current release workflow does not package a headless archive. Build that surface from source when you need it.

## Build from source

The repository expects the MoonBit toolchain. `cetas-js` additionally requires Bun.

### Interactive terminal (`cetas-js`)

```bash
cd cetas-js
bun install
bun run build
```

For a source checkout with dependencies resolved, the terminal entry point is available through:

```bash
bun run start
```

### ACP (`cetas-acp`)

```bash
cd cetas-acp
moon build --target native --release
```

### Headless (`cetas-headless`)

```bash
cd cetas-headless
moon build --target native --release
```

See [Quick Start](/docs/getting-started/) for the configuration required before the first prompt.
