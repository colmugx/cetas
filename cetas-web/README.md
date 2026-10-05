# cetas-web

Bootstrap for the web-native Cetas host.

This directory intentionally starts with the smallest architecture slice that fixes the
host boundary:

- **Solid 2** owns browser UI and fine-grained reactive state.
- **Moonback** owns HTTP, WebSocket, static assets, and the native server process.
- **Cetas protocol** will connect them; the browser does not own the agent loop.
- Production static assets enter Moonback through `web_assets() -> Map[String, Bytes]`.

The current PR is phase 0. It proves the frontend/server boundary and leaves Cetas session
composition for the next slice.

## Layout

```text
cetas-web/
├── server/             MoonBit + Moonback native host
│   ├── main.mbt
│   └── web_assets.mbt  production embedding seam (empty in this bootstrap)
└── web/                Solid 2 client app
    ├── src/
    └── vite.config.ts
```

## Requirements

- MoonBit toolchain
- Node.js 22.12 or newer

Solid 2 is intentionally pinned to the current release-candidate line. Direct dependencies
use exact versions so an RC update is an explicit repository change.

## Development

Start Moonback from the repository root:

```sh
moon run ./cetas-web/server
```

Then start the Solid dev server:

```sh
cd cetas-web/web
npm install
npm run dev
```

Vite serves the frontend on port 5173 and proxies:

```text
/api/* -> http://127.0.0.1:8787
/ws     -> ws://127.0.0.1:8787/ws
```

The bootstrap UI displays HTTP and WebSocket connectivity.

## Static production build

Build Solid:

```sh
cd cetas-web/web
npm run build
```

Solid start mode emits a static client build under:

```text
cetas-web/web/dist/client/
```

While `web_assets()` is empty, Moonback serves that directory from disk. Set
`CETAS_WEB_DIST` to point at another build directory.

The next packaging slice will turn the same directory into a generated
`Map[String, Bytes]` and feed it through Moonback's `from_assets` middleware. At that
point the release artifact becomes a single native executable without a sidecar static
directory.

## Bootstrap endpoints

```text
GET /api/health
GET /ws
```

The WebSocket currently sends a connection envelope and echoes frames. It is deliberately
not the Cetas turn protocol yet.

## Next slice

1. Add the `web` composition recipe and build a long-lived Cetas session runtime.
2. Define the first realtime protocol envelopes: attach, turn start, text delta, tool
   lifecycle, completion, abort, and reconnect sequence numbers.
3. Generate the static asset map during release builds.
4. Add protocol replay fixtures before the UI grows around the wire format.
