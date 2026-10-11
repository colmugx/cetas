# Private extensions for Cetas JS

This is an **opt-in source-level composition seam**. Public Cetas builds contain
no dependency or imports for Zcode, Obsidian, or Nowledge Mem. Unlike the old
`prepare-recipe.py`, no code generation, file swapping, or build-time CSV
projection is involved.

## Where to add the extensions

Keep your implementation on a **private Git branch or fork**, not `main`.
The sole MoonBit implementation file to edit is:

```text
cetas-js/lib/private_recipe.mbt
```

It is already wired into the JS agent's normal composition path:

- `append_private_recipe_features` runs **before** LazyTools wraps episodic
  extensions; add **Nowledge Mem** and **Obsidian** to `episodic`.
- `build_compiled_zcode_ext` is called separately by the JS parent-agent
  composition after the public features and subagent composition; implement
  **Zcode** there.

The checked-in default hooks are no-ops. Editing them **only** in your private
branch keeps public builds free of private dependencies. Don't create a second
`recipe.generated.mbt`, and don't run the removed generator.

## Declare private MoonBit dependencies

On your private branch, add the three modules to
`cetas-js/moon.mod` inside `import { ... }`:

```moonbit
// Read the versions from the private modules' own moon.mod files.
"colmugx/posoco-ext-zcode@<version>",
"colmugx/posoco-ext-obsidian@<version>",
"colmugx/posoco-ext-nowledge-mem@<version>",
```

Then add their package imports to `cetas-js/lib/moon.pkg`:

```moonbit
"colmugx/posoco-ext-zcode" @zcode,
"colmugx/posoco-ext-obsidian" @obsidian,
"colmugx/posoco-ext-nowledge-mem" @nmem,
```

These import lines are **examples** to insert into the existing blocks, not
standalone replacement manifests. Ensure the private packages are available in
your Moon workspace (for example via the private extensions checkout); do not
invent versions or silently drop missing dependencies. No other host's Moon
manifest needs to change.

## Implement Nowledge Mem and Obsidian

Replace the body of `append_private_recipe_features` in
`cetas-js/lib/private_recipe.mbt` with code along these lines, retaining its
signature:

```moonbit
  let _ = exts

  let nmem = @nmem.NowledgeMem(
    source_app="cetas",
    transport=@nmem.HttpNmemTransport::HttpNmemTransport()
      as &@nmem.NmemTransport,
    mcp=@nmem.LazyNmemMcp::LazyNmemMcp() as &@nmem.NmemMcp,
    platform=@nmem.PlatformFs::PlatformFs() as &@nmem.NmemPlatform,
  )
  match nmem_group {
    Some(group) => nmem.attach(group)
    None => ()
  }
  episodic.push(nmem as &@posoco.Extension)

  let vault : String? = match obsidian_vault {
    Some(name) => Some(name)
    None =>
      match @env.get_env_var("CETAS_OBSIDIAN") {
        Some(value) if value != "on" && value != "1" && value != "off" =>
          Some(value)
        _ => None
      }
  }
  episodic.push(
    @obsidian.ObsidianTools::new(
      config=@obsidian.ObsidianConfig::ObsidianConfig(
        vault~,
        read_only=false,
      ),
    )
    as &@posoco.Extension,
  )
  let _ = ctx
```

This adapts the constructors from the former generator. Confirm the actual
versions and APIs in your private packages if they have since changed.
Attaching Nowledge Mem to the agent's task group preserves its lifetime.

## Implement Zcode

Replace the body of the existing `build_compiled_zcode_ext` stub (keep the
async function signature):

```moonbit
  let detected = @zcode.zcode_ext_if_detected(env~, exists~) catch {
    _ => None
  }
  match detected {
    Some(ext) => Some(ext as &@posoco.Extension)
    None => None
  }
```

Do **not** add another function with the same name. The JS parent agent already
calls this hook with its environment reader and workspace filesystem probe.

## Build and validate

From the Cetas workspace root with your private modules checked out:

```sh
moon update
moon check --target js --deny-warn
cd cetas-js
bun install --frozen-lockfile
bun build.ts --dts-only
bun build.ts linux-x64
```

A private build is selected by **the private source and dependencies in your
worktree**, not `CETAS_FLAVOR`. Don't set `CETAS_FLAVOR=private`: it is an old
generator switch and no longer selects a recipe.

Before upstreaming anything, make sure the public branch still has only the
no-op hooks and no private imports. Avoid committing local vault settings,
credentials or private package source to the public repository.
