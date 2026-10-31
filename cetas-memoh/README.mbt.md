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


## First-run setup

A fresh Memoh-only workspace does not need a separate Cetas installation or
generic `~/.cetas` configuration. Bootstrap one runnable model provider from
a controlling terminal:

```sh
cetas-memoh setup
```

Or select a bootstrap-ready provider directly:

```sh
cetas-memoh setup openai
cetas-memoh setup kimi
cetas-memoh setup opencode
cetas-memoh setup zai
cetas-memoh setup zai-coding-plan
```

Credential input is read from the controlling terminal with echo disabled. It
is never accepted through ACP stdin or a command-line argument. The provider
extension owns prompting and validation; Cetas-Memoh persists the resulting
record through `FileProviderCredentialStore` only after the credential can
produce a non-empty offline model catalog.

DeepSeek and OpenRouter are intentionally not first-run choices: without a
cached catalog they also require non-secret model settings. After any bootstrap
provider starts Cetas, activate the built-in `cetas-memoh-config` manual and
use Memoh Tools to configure those non-secret settings.

The Memoh composition also includes:

- built-in Cetas identity, usage, and Memoh-specific configuration skills;
- `ask_question`, rendered through Memoh's ACP elicitation surface;
- LazyTools around the Memoh Tools MCP catalog, so the full platform tool
  schemas are loaded only when needed.

It deliberately does not add parallel local filesystem, shell, web, memory,
context, or permission extensions; those remain Memoh-owned surfaces.

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

The bridge is not optional yet. Every `colmugx/posoco-ext-*` import in
`moon.mod` is absent from the registry, so a standalone `moon update` fails
with `module was not found in the registry`; deleting the script or the pin
breaks CI and the release job. The pin must also contain every module in the
closure, including transitive `posoco-kit-*` ones — a missing member fails
resolution the same way. Bumping `EXTENSION_REV` is the supported way to move
the bridge forward; keep `MEMBERS` a closure over the revision, not a wish list.

## Runtime ownership

- Memoh owns durable conversation continuity.
- Memoh Tools is the only platform/workspace MCP surface consumed here.
- Posoco owns the agent/tool loop.
- `RouterModelPort` owns model execution.
- Cetas-Memoh persists provider configuration/credentials only.

No JSONL conversation transcript is written by this runtime.

## Provider home

`CETAS_MEMOH_HOME` overrides the provider-state directory. Otherwise the
runtime resolves it in this order:

1. `CETAS_MEMOH_HOME`, always;
2. `/data/.cetas-memoh` when `/data` exists — Memoh's workspace mount;
3. `$HOME/.cetas-memoh`;
4. `.cetas-memoh` relative to the working directory.

Step 2 exists because Memoh's generic ACP runtime storage policy launches
agents with `HOME=/data`, while a shell opened in the same container usually
carries `HOME=/root`. Resolving from `HOME` alone would send `cetas-memoh
setup` output into `/root/.cetas-memoh`, where the runtime never looks. Inside
a Memoh workspace the effective home is:

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

Custom provider ids are served by `posoco-ext-custom`, which reads the entry's `protocol` (`chat_completions`, `responses`, or `messages`).

The credential directory uses the canonical
`posoco-ext-credentials::FileProviderCredentialStore` record format.

## ACP surface

The ACP runtime advertises:

- image prompts;
- embedded context;
- HTTP MCP;
- session resume;
- session close.

`session/resume` is what keeps a conversation alive across process replacement.
Memoh swaps the ACP process on any launch-configuration change, after the
runtime sits idle (30 minutes for a bound session), when the workspace
container restarts, and when the Memoh server restarts. It then resumes the
agent's own session instead of starting a new one. This runtime holds no
transcript, so resume replays nothing: it rebuilds the session's live objects
under the stored id and returns the same model/effort options `session/new`
would. The conversation itself was never in this process.

A session is rejected unless the ACP client identifies itself as `memoh`.
Memoh opens two shapes of session on one runtime, and they carry different
tool surfaces:

- a **conversation**, which always injects the Memoh Tools HTTP MCP server;
- a **transient probe** (how the model/effort picker reads its options), which
  declares no MCP server at all and never prompts.

Memoh Tools are therefore required for real work but never for session
creation. A missing gateway, or a gateway that cannot be reached, degrades the
session instead of failing it: the conversation still answers, stderr records
why, and the system prompt tells the model that no platform action may be
claimed. Connection is attempted up to three times over about a second, because
Memoh registers the gateway route just after it starts a session and a
one-shot attempt can lose a race it would win moments later. A malformed
declaration (duplicate, stdio, SSE, empty URL) still fails closed, because that
is a contract we cannot honour rather than a surface that is merely absent.

The runtime uses the first configured Router slot and intentionally persists
no active selection.

### Deferred: connection-lazy Memoh Tools

Ported from a 2026-10-31 design review, so the next reader does not re-derive it.

Two independent laziness goals exist and they currently exclude each other:

- **schema laziness** — keep the platform tool schemas out of the prompt and
  expose `tool_list` / `tool_execute` (`@lazytools.LazyTools::defer_extensions`,
  used here);
- **connection laziness** — do not dial the gateway until a turn needs it
  (`@mcp.LoadMode::Lazy` plus the bridge's first-turn `on_start` activation and
  its dynamic tool-contribution group).

Schema laziness forces an eager connect: `LazyTools::build` calls
`provider.list_tools()` at composition (`posoco-ext-lazytools/src/lazytools.mbt`),
and the bridge lists only connected servers
(`posoco-ext-mcp/src/posoco_ext_mcp.mbt`, `ToolProvider::list_tools`). Lazy
connect in turn publishes the bridge's full tool group on the first turn, which
would bypass the gateway. `cetas-acp` resolves the same conflict the same way:
injected servers connect at `session/new` even under `--mcp-mode lazy`
(`cetas-acp/lib/host.mbt`).

The current decision is schema laziness, with a three-attempt bounded retry
absorbing Memoh's route-registration race. Getting **both** later needs, in
order: a public way to enqueue an injected `MCPServerConfig` into the bridge's
`pending` set and select `Lazy` (`MCPToolBridge::discover` is the only writer
today, and it reads `mcp.json`), then moving schema hiding from LazyTools to the
kernel's native deferred exposure (`ToolDef::exposure` / `PipelineHook::tool_exposure`),
which Cetas has not migrated to yet.

Related upstream doc debt: `posoco-ext-mcp/src/runtime_adaptor.mbt` still
describes wiring `catalog_source=McpCatalogSource(...)`, but `catalog_source`
does not exist in Posoco 0.23.1; the live channel is
`Capability::ToolContribution` captured in `Lifecycle::on_compose`.

## License

Apache-2.0
