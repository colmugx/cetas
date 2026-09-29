# cetas-memoh

`cetas-memoh` is the Cetas product composition for running a Posoco agent as
a first-class Memoh ACP runtime.

It deliberately does **not** depend on `cetas-core`. Memoh-specific semantics
live in `posoco-ext-memoh`; this module owns process/session composition and
provider configuration.

## Release and installation

`cetas-memoh` has its own version and release train. It does not follow the
Cetas product version. The current version is **0.1.0**, released from tags of
the form `cetas-memoh-vX.Y.Z`.

The supported release target is **Linux x86_64** (including Debian GNU/Linux 13
/ trixie). The release asset is:

```text
cetas-memoh-linux-x64.tar.gz
```

Install the current release to `~/.local/bin`:

```sh
./install.sh
```

Install a specific version:

```sh
./install.sh 0.1.0
```

Override the destination with `CETAS_MEMOH_INSTALL_DIR`. The installer
downloads the GitHub Release asset and verifies `SHA256SUMS-memoh` before
installing the binary.

## Development workspace

Some Posoco extension modules used by `cetas-memoh` are not yet published to
the Moon registry. Until they are, the subtree pins a source revision in
`EXTENSION_REV`. Prepare the local workspace with:

```sh
python3 scripts/bootstrap_workspace.py
moon update
moon check --target native
```

The bootstrap clones `posoco-extension` into the ignored `.deps/` directory
and generates an ignored local `moon.work`. This temporary bridge is contained
inside `cetas-memoh/` so the subtree can move to its own repository cleanly.

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

The ACP runtime advertises:

- image prompts;
- embedded context;
- HTTP MCP;
- session close.

A session is rejected unless the ACP client identifies itself as `memoh` and
injects the Memoh Tools HTTP MCP server.

The runtime uses the first configured Router slot and intentionally persists
no active selection.

## License

Apache-2.0
