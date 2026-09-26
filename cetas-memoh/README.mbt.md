# cetas-memoh

`cetas-memoh` is the Cetas product composition for running a Posoco agent as
a first-class Memoh ACP runtime.

It deliberately does **not** depend on `cetas-core`. Memoh-specific semantics
live in `posoco-ext-memoh`; this module owns process/session composition and
provider configuration.

## Runtime ownership

- Memoh owns durable conversation continuity.
- Memoh Tools is the only platform/workspace MCP surface consumed here.
- Posoco owns the agent/tool loop.
- `RouterModelPort` owns model execution.
- Cetas-Memoh persists provider configuration/credentials only.

No JSONL conversation transcript is written by this runtime.

## Provider home

`CETAS_MEMOH_HOME` overrides the provider-state directory. Otherwise the
runtime uses `$HOME/.cetas-memoh`.

Memoh's generic ACP runtime storage policy currently launches agents with
`HOME=/data`, so the in-workspace default is:

```text
/data/.cetas-memoh/
├── providers.json
└── credentials/
```

`providers.json` is a direct object keyed by provider id. Values are opaque
provider-extension settings, for example:

```json
{
  "openai": {},
  "openrouter": {}
}
```

Custom provider ids are served by `posoco-ext-openai-compatible`.

The credential directory uses the canonical
`posoco-ext-credentials::FileProviderCredentialStore` record format.

## ACP surface

V1 bootstrap advertises:

- image prompts;
- embedded context;
- HTTP MCP;
- session close.

A session is rejected unless the ACP client identifies itself as `memoh` and
injects the Memoh Tools HTTP MCP server.

Model/effort config options are added in the next iteration; this bootstrap
uses the first configured Router slot and intentionally persists no active
selection.

## License

Apache-2.0
