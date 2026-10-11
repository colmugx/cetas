# Cetas composition roster

`recipes.csv` documents the historical public capability roster; executable
public composition is now checked in as `recipe.mbt` in each host.

## Ownership

- **cetas-core** owns Cetas product semantics: identity, session/agent
  lifecycle, prompts, routing, policy and product ordering.
- **hosts** (`cetas-run`, `cetas-acp`, `cetas-js`) are composition roots.
  They bind concrete extensions and platform/protocol adapters.
- **this roster** is the single human-edited inventory from which host
  dependency/import/constructor projections are generated.
- **the generator is infrastructure only**: it binds logical capabilities to
  concrete packages/constructors. Product behavior and capability policy stay
  in `cetas-core` and are consumed by generated host code.

## Vocabulary

- `section=general`: a standard Cetas capability shared by every host.
- `section=special`: a capability or adapter specific to one host/flavor.
- `scope=base`: stable infrastructure already owned by the application
  layer; listed for inventory only.
- `scope=core`: a concrete capability constructed by the generated host
  recipe.
- `scope=host`: a host integration constructed by handwritten host code but
  retained in the roster/dependency projection.

`runtime_key` lets several concrete packages represent one product
capability. For example Bash and PowerShell both project to the logical
`shell` capability; platform binding selects the concrete implementation.

## Developer workflow

Public hosts compile their checked-in `recipe.mbt` directly:

```sh
moon update
moon check --deny-warn
```

The Python generator is retained temporarily for historical/private migration,
but must not be run in the public build: it creates duplicate recipe sources.
Private flavors require a separate composition-root migration.

Do not add dependency fallbacks for missing modules. A selected capability
whose module/target is unavailable is intentionally a Moon build-plan or
compile error.
