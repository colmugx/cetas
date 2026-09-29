# cetas-js terminal UI

`ui/` is the pi-tui adapter for the provider-neutral cetas application. It
owns terminal layout, input focus, slash-command interaction, model/effort
selection, OAuth progress, extension UI mounts, and the transcript renderer.
`host.ts` only wires a `CetasApplication` to this adapter and starts the
process.

## Boundaries

- `src/app/` owns application state and the long-lived Agent handle.
- `src/events.ts` owns the observer wire protocol; the UI parses it once and
  routes it to the transcript/event controller.
- Provider setup is consumed only as safe capability snapshots. The UI does
  not parse settings, credentials, endpoints, or provider-specific request
  payloads.
- `/model` consumes the cached command model-slot catalog. Its pi-tui overlay
  follows Kimi Code's selector shape: `All` plus provider tabs, independent
  vertical model cursors per tab, and left/right effort segments on the
  selected model. A model with no advertised efforts never gets a synthetic
  effort row.
- `/login` first selects a provider and, when it exposes more than one
  capability, a second-level method (`API key` or `OAuth`). `/login <provider> [method]`
  is the equivalent direct form. API-key prompts are masked and
  provider-neutral; OAuth keeps an overlay mounted while the command runs.
  `custom` observer events with the OAuth interaction vocabulary render the
  authorization URL, device code, and progress. URLs are displayed as pi-tui
  Markdown links; the UI never shells out to open or copy them.
- Streaming assistant text, reasoning, tool rows, and turn failures continue
  through `EventRouter` and the existing transcript components.

The adapter is intentionally fail-fast: malformed capability, command, event,
or OAuth interaction data raises an error and is shown in the transcript/logs.
