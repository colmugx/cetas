# Development

[← Cetas](../README.md) · [Architecture](architecture.md)

## Workspace setup

Use the Posoco parent workspace, as CI does, so the repository and its nested extension submodule are present together:

```bash
git clone --recurse-submodules https://github.com/colmugx/posoco.git
cd posoco/external/cetas
# For development against the current Cetas branch:
git checkout main
git pull --ff-only
git submodule update --init --recursive
```

Install the [MoonBit toolchain](https://docs.moonbitlang.com), Python 3, and [Bun](https://bun.sh) for the JS host. The native terminal additionally needs Rust/Cargo. Stay in the **Cetas repository root** for workspace-wide Moon commands: `moon.work` assembles the Cetas modules and extensions.

Prepare the public recipe before building or checking:

```bash
python3 scripts/prepare-recipe.py --flavor public --frontend all --platform unix
moon update
```

Use `--platform windows` on Windows. Recipe generation writes an ignored `recipe.generated.mbt` and updates marked dependency/import regions. See [composition](../composition/README.md) before changing capabilities.

## Interactive terminal

```bash
cd cetas-js
bun install --frozen-lockfile
bun run start
```

The preload hook compiles the MoonBit bridge before loading the TypeScript host. To produce a standalone executable for a specific platform:

```bash
bun build.ts linux-x64
# Also supported: darwin-arm64, darwin-x64, linux-x64-musl,
# linux-arm64, windows-x64.
```

Outputs are written to `cetas-js/dist/cetas-bun-<platform>`. `bun run build` builds all supported targets.

To use the executable on a different repository, launch it from that project's directory. Running the development host directly uses the current process working directory.

## Editor and runner

From the Cetas repository root, after preparing the recipe:

```bash
moon build cetas-acp/main --target native --release
moon build cetas-run/main --target native --release
```

Native artifacts are under `_build/native/release/build/`. See [ACP setup](configuration.md#editor--acp) and the [runner guide](../cetas-run/README.mbt.md).

For the native terminal and web host, use their dedicated guides:

- [Native terminal](../cetas-native/README.md)
- [Web development](../cetas-web/README.md)

## Checks

Choose checks that cover the changed area. CI includes:

```bash
# From the Cetas repository root:
python3 scripts/prepare-recipe.py --flavor public --frontend all --platform unix
moon check --deny-warn --output-json
moon fmt --check
moon info
moon test --target native --output-json
```

`moon info` should not leave unintended tracked interface changes. For the JS host:

```bash
cd cetas-js
bun install --frozen-lockfile
bun build.ts --dts-only
bun run typecheck
bun test
```

The generated `gen/mbt.d.ts` is required for full TypeScript checking, and normal tests use `moonbit-preload.ts` to prepare the runtime. For an isolated UI-only test when the Moon toolchain is unavailable, run from outside `cetas-js` so its `bunfig.toml` preload is not loaded:

```bash
# From the Cetas repository root:
bun test ./cetas-js/ui/welcome-header.test.ts ./cetas-js/ui/terminal-shell.test.ts
```

This tests terminal rendering and headless shell behavior; it does not validate the MoonBit bridge or a live provider.

## Contribution boundaries

- Keep identity, prompts, lifecycle, and product policy in `cetas-core`.
- Keep transport, terminal mechanics, and UI rendering in the corresponding host.
- Update `composition/recipes.csv` for capability inventory changes, then regenerate.
- Keep public builds free of private recipe overlays and user credentials.

See the [CI workflow](../.github/workflows/ci.yml) for the complete validation sequence.
