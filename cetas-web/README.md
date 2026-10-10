# cetas-web

Web-native Cetas host.

The browser UI is deliberately a separate runtime from the agent:

- **Solid 2** owns browser interaction and fine-grained reactive presentation.
- **Solid Router 2** owns the client application route tree.
- **Tailwind CSS v4** provides the styling pipeline.
- **Lucide Solid 2** provides the initial icon set.
- **Moonback** owns HTTP, WebSocket, static assets, and the native server process.
- **cetas-core** still owns Cetas product semantics, provider/model setup, sessions, tools, and the Posoco agent lifecycle.
- Production assets enter Moonback through `web_assets() -> Map[String, Bytes]`.

The current draft is intentionally a day-1 application shell rather than a complete chat implementation. It composes the real Cetas runtime and exposes that boot state to the frontend, while the turn protocol remains the next architectural slice.

## Layout

```text
cetas-web/
├── moon.mod
├── server/
│   ├── main.mbt
│   ├── runtime.mbt
│   ├── recipe.generated.mbt
│   └── web_assets.mbt
└── web/
    ├── src/
    │   ├── cetas/       HTTP/WS client + runtime context
    │   ├── components/  application shell
    │   ├── pages/       Chat / Workspace / Settings
    │   └── ui/          Cetas-owned primitive facade
    └── vite.config.ts
```

## Frontend baseline

The Solid 2 ecosystem is still converging, so versions are deliberately exact rather than broad ranges.

```text
solid-js              2.0.0-rc.13
@solidjs/web           2.0.0-rc.13
@solidjs/vite-plugin   3.0.0-next.47
@solidjs/router        2.0.0-next.35
@lucide/solid          1.52.0
Tailwind CSS           4.3.3
Vite                   8.3.2
```

Do not use the Solid 1 `lucide-solid` or Solid Router 1.x packages in this application.

Headless component libraries are intentionally kept behind `src/ui/`. Kobalte and Ark UI can be evaluated as their Solid 2 support settles; application components should not import a third-party primitive library directly.

## Cetas runtime

The native process now composes the same core assembly used by other Cetas hosts:

```text
build_cetas_platform
       ↓
build_compiled_recipe_features
       ↓
build_cetas_session
       ↓
compose_cetas_agent
```

The Web bootstrap starts in `ReadOnly` permission mode until the approval surface is wired.

If provider/settings composition succeeds, `GET /api/runtime` reports a real session id, active model, effort, and cwd. If setup is incomplete, the HTTP server still starts and reports `needs_setup` so the browser can remain usable for the future setup UI.

## Development

Requirements:

- MoonBit toolchain
- Node.js 22.12 or newer

Prepare the public console recipe when working on composition code (the
recipe now lives in the shared `cetas-console` core, not in this host):

```sh
python3 scripts/prepare-recipe.py \
  --flavor public \
  --frontend console \
  --platform unix
```

Start Moonback from the repository root:

```sh
moon run ./cetas-web/server
```

Then start Solid:

```sh
cd cetas-web/web
bun install
bun run dev
```

Vite serves the frontend on port 5173 and proxies:

```text
/api/* -> http://127.0.0.1:8787
/ws     -> ws://127.0.0.1:8787/ws
```

The day-1 shell has Chat, Workspace, and Settings routes. Chat shows the real core boot state; the composer is intentionally disabled until the realtime turn contract exists.

## HTTP bootstrap

```text
GET  /api/health
GET  /api/versions        posoco / cetas / web versions
GET  /api/runtime          ready state incl. active model, effort, permission
GET  /api/workspaces       registered workspaces (cwd-scoped cetas instances)
POST /api/workspaces       {cwd} register/switch; composes lazily on first touch
GET  /api/sessions         persisted sessions for the active workspace
GET  /api/sessions/:id/transcript   replay projected into transcript items
POST /api/sessions/:id/rename     {name} persist a display name
POST /api/session          {id?} switch to id, or mint a new session
GET  /api/models           router slot catalog with per-slot efforts
POST /api/model            {slot_id} switch model (persists to settings.json)
POST /api/effort           {effort} select reasoning effort (persists)
POST /api/permission       {mode} readonly | workspace_write | yolo
GET  /ws                   realtime turn protocol
```

Each workspace is an independent Cetas (platform + session bucket per cwd,
composed lazily on first touch); sessions within a workspace run concurrently
through per-session handles sharing one broadcast EventHub. Switching a
session recomposes its agent; the browser receives a fresh `session.snapshot`
and replays the persisted transcript through the same rendering path as live
turns. Store access beyond the
kernel's `@port.SessionStore` (list/entry/name) goes through the server-local
`SessionCatalog` seam (`server/catalog.mbt`); swap store implementations by
writing one adapter.

The approval surface is wired: composing a session bridges a `WsUiPort`
(`server/uiport.mbt`) into `UiBlockingApprovalSource` (`server/approval.mbt`),
so `interactive` mode routes tool asks to a composer takeover card over the
`ui.request`/`ui.response` protocol. Denials fold back into the turn as
`NotExecuted` results — non-terminal steering, matching the cetas-js bridge.
`auto` still requires a `DecisionPort` and stays refused.

Observability: `GET /api/exts` projects the live extension manifests of the
active workspace (tools, commands, port roles — the "zoo", rendered as
expandable blinds — each blind body lists every port role the manifest
fills (h2 per role, h3 per capability; tool/command/prompt/ui details come
only from port contracts)), and `GET /api/trace` serves **per-turn ledgers** —
the path each answer took, one event list per turn. The Trace page is a turn
browser (ledger sidebar + typed event rows + raw payload expansion), and each
answer's footer opens the same ledger as a float window. Every wire event
carries a `ts` stamp; message headers/footers show sender, model/turn, and
completion time. The chat header gains a float window on persisted sessions
listing every posoco-ext with a participation dot (green = contributed this
session), driven by the trace. Usage & provider status: `ModelResponseReceived` usage deltas and
`ContextStateUpdated` drive a Settings "Context & usage" section and a slim
composer meter, recomputed from the turn ledgers so they survive reloads.
The bottom-left Status Window is fully data-driven: it renders whatever
segments the active provider's publishers push onto the session bus
(ratelimit windows render as progress bars; a provider balance renders as a
plain row) — the title comes from the active slot's label prefix, with no
provider-specific client branches. Connection state (api/ws/core) lives in
Settings.

Composer controls: model and effort are one cascading picker (effort chips
pin to the top of the model menu, scoped to the highlighted model); the
statusbar dock excludes keys the composer already shows. The
statusbar pipeline is composed end-to-end: `posoco-ext-stats` derives
ttft/tps/avg/cache from turn events, the web host publishes turns/steps
counters, `posoco-ext-statusbar` aggregates them on the event bus and pushes
`ui.render(key="statusbar")` through the host UiPort — rendered as
composer-dock pills under the input box (activity: turns/steps/tok-per-sec;
usage: tokens/cache-hit; plus leftover segments like rate-limit windows),
recomputed from the turn ledgers so they survive reloads. The socket
auto-reconnects with backoff and re-attaches on server restarts. Message headers are reserved for attachments;
footers carry the quick menu (trace/copy) and completion time.

Prompts typed while a turn runs queue on the session and dispatch
automatically when it settles (steering-compatible; mid-turn injection
awaits core support). Keyboard: Esc aborts, Cmd/Ctrl+Shift+O opens a new
session, Cmd/Ctrl+B folds the sidebar, ? shows the shortcut sheet.

`/ws` still sends a connection envelope and echoes frames. It is not yet the final Cetas turn protocol.

## Static production build

```sh
cd cetas-web/web
bun run build
```

Solid 2 start mode emits the static client build under:

```text
cetas-web/web/dist/client/
```

While `web_assets()` is empty, Moonback serves that directory from disk. `CETAS_WEB_DIST` can point at another build directory.

The packaging slice will generate `web_assets.mbt` from the same directory and serve it through Moonback `from_assets()`, producing a single native executable without a sidecar static directory.

## Next slice

The next architectural change should define the realtime protocol before enabling the composer:

1. session attach + snapshot
2. stable event id / sequence number
3. turn start / abort / follow-up
4. text + reasoning deltas
5. tool lifecycle
6. approval / UI request-response
7. reconnect + replay

After that, the day-1 shell can become the first real Cetas Web transcript without changing the core/runtime boundary.
