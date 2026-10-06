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

Prepare the public Web recipe when working on composition code:

```sh
python3 scripts/prepare-recipe.py \
  --flavor public \
  --frontend web \
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
GET  /api/sessions         persisted sessions for this cwd bucket
GET  /api/sessions/:id/transcript   replay projected into transcript items
POST /api/sessions/:id/rename     {name} persist a display name
POST /api/session          {id?} switch to id, or mint a new session
GET  /api/models           router slot catalog with per-slot efforts
POST /api/model            {slot_id} switch model (persists to settings.json)
POST /api/effort           {effort} select reasoning effort (persists)
POST /api/permission       {mode} readonly | workspace_write | yolo
GET  /ws                   realtime turn protocol
```

Session switching recomposes the agent over the shared platform; the browser
receives a fresh `session.snapshot` and replays the persisted transcript
through the same rendering path as live turns. Store access beyond the
kernel's `@port.SessionStore` (list/entry/name) goes through the server-local
`SessionCatalog` seam (`server/catalog.mbt`); swap store implementations by
writing one adapter. `interactive`/`auto` permission modes need the approval
surface, which is not wired yet.

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
