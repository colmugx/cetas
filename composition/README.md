# Cetas composition

Each host's committed `recipe.mbt` is executable composition source.
`moon.mod` and `moon.pkg` explicitly declare the dependencies and aliases
used by that host. There is no CSV-to-MoonBit generation step.

## Ownership

- **`cetas-core`** owns identity, product ordering, lifecycle, prompts,
  routing, and policy.
- **Hosts** (`cetas-run`, `cetas-acp`, `cetas-js`, `cetas-native`,
  and `cetas-console`) are composition roots: they bind concrete extension
  constructors and platform or transport adapters.
- **Moon manifests** own the exact build-time package graph.

To change a public capability, edit the corresponding host's `recipe.mbt`
and its `moon.mod` / `moon.pkg` imports. Do not generate or rewrite source
files in CI.

## Development

```sh
moon update
moon check --deny-warn
moon fmt --check
```

The JS host has optional **private** no-op hooks in
[`cetas-js/lib/private_recipe.mbt`](../cetas-js/lib/private_recipe.mbt).
Use the [JS private extension guide](../cetas-js/PRIVATE_EXTENSIONS.md)
to fill them in on your own private branch. Public CI never imports private
packages; unavailable explicit private dependencies must fail a Moon build,
not silently fall back.
