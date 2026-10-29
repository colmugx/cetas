# Changelog

Entries in this file are written by `scripts/release.py` at release time, as `## X.Y.Z (YYYY-MM-DD)` sections ordered newest first.

## 0.10.13 (2026-10-29)

## Bun Ver.（cetas-bun）

### Feats

- `/sessions` now has two scopes, `Current Folder` and `All` (press `tab` to switch): `All` mixes sessions from every project newest-first, labels each row with the folder it belongs to, and resuming a row from another project switches cetas into that directory — tools, workspace anchor and session bucket follow — before replaying that transcript.
- Board tickets can now be brought to the Scrum Master: ask a question about blockers, dependencies or the next step from the ticket sheet, and the answer arrives as a background advice run that never changes the ticket.
- The Scrum Master answers with the ticket's real coordination facts already in hand (stage, dependency states, other running work, open questions) plus read-only tools to re-read them by topic, instead of rediscovering the board on every question.
- Board teams now have a Scrum Master next to the Product Owner, and role names, skills and MCP tool selections are configured per role, so the Board addresses members by name ("Answer as Product Owner") instead of by raw role id.

### Fixes

- The Board dashboard now works in the npm channel, which runs on plain Node.
- Streamed tool calls are matched to the right row: a call arriving in fragments no longer adopts an unrelated pending call, and a missing provisional row can no longer break the turn's tool display.

## 0.10.12 (2026-10-28)

## Bun Ver.（cetas-bun）

### Feats

- A Board ticket is now carried by three accountable roles instead of one anonymous worker.
- Your configured MCP servers now reach Board team members.
- Board team settings are now per role and per project.
- A work profile (Software / Document / Analysis) changes what the team produces — the deliverable, the checks designed against it, and what verification means — without changing the team structure.
- Team questions now name their audience: requirement and design questions go to the Refiner, business trade-offs to you as Product Owner, and the inbox shows the route by member name instead of raw role ids.
- A new backlog item starts from a plain-language idea ("What do you want to build?"); the Refiner turns it into a three-line user story, rewrites the title, and fills in definition of done and priority.
- Work reports are recorded against the role that produced them, and Review falls back to the TE's result when no structured report was submitted, so a finished ticket never opens with an empty report.
- Opening the Board now tells you, in the session, that cetas is acting as your Product Owner for that Board and will coordinate your questions and requirements with the team.

## 0.10.11 (2026-10-27)

## General

### Fixes

- Nested tool calls made from inside `run_code` are now bounded to a fixed depth: a runaway chain stops with an invocation-limit result instead of recursing without end.
- Tool arguments are now checked against the full JSON Schema 2020-12 profile before a tool runs. Tools whose schemas use `oneOf`/`anyOf`/`$ref`, `pattern`, or numeric bounds now load correctly, and arguments that violate the schema are reported up front instead of failing inside the tool.

## Bun Ver.（cetas-bun）

### Feats

- A ticket can no longer be marked Ready until the story, description, implementation suggestions, and at least one definition-of-done item all exist — the Board tells you which field is still missing.
- Board questions now show who asked them and who they are addressed to, and answers record who answered; answering from the Board also posts an "answered" entry in the run's progress feed.

### Fixes

- Cancelling a turn now verifies the shell command actually stopped: a graceful signal, then a hard kill with a bounded confirmation wait. Commands that ignore the graceful signal are killed and reported as stopped instead of leaving a live process (and its concurrency slot) behind.
- In PTC-only mode, calling a tool that is folded into `run_code` now returns guidance telling the model to call it through `ctx.call(...)`, instead of a bare "not executed".

## 0.10.10 (2026-10-26)

## General

### Feats

- A conversation model and a decision model can now be chosen independently: `/decision` lists the provider's decision slots (with the active marker), rejects a chat slot, `/model` rejects a decision slot, and the choice is stored next to `model` in `~/.cetas/settings.json` so the terminal and ACP hosts restore it on the next start.
- Decision backends for more providers: OpenRouter `typesafe/jev-*` models, OpenCode Zen's SystemOne endpoint, and a dedicated Typesafe `jev` provider, each with its own credentials, timeout handling, and provider-specific errors instead of borrowing another provider's backend.

### Fixes

- A model-stream parse failure now reports the parse error plus the payload head and tail, so malformed tool arguments are diagnosable from the error itself.

## Bun Ver.（cetas-bun）

### Feats

- `/board` now opens the Board dashboard in your browser, and each ticket runs as a background worker with its own durable session.
- Follow Board work from the terminal: the Activities header shows the shaping or working ticket, its step count, elapsed time, and current tool or latest activity, without opening the dashboard.
- The agent can answer "why does this code exist?": `board_work` reports current tickets, finds tickets whose committed review mentions a path or ticket id, and shows one ticket's review report and feedback; opening the Board also tells the agent once to check provenance before deleting or reverting work.
- Splitting an oversized ticket now cancels the source ticket instead of deleting it, preserving its description and attempt history.

### Fixes

- Switching the model manager stops the open Board and says to reopen it with `/board`, instead of leaving a stale dashboard behind.
- `run_code` now selects each scoped tool from multi-tool providers, can run `bash` inside the nested scope without exposing shell session helpers, caps model-visible compiler diagnostics at 8K characters, and rejects untransportable attachments with an explicit error instead of dropping them.
- Failures in background work (live model-catalog refresh, Board command replies) are reported as errors instead of becoming unhandled rejections that take down the terminal.

## ACP Ver.（cetas-acp）

### Feats

- The saved `/decision` model survives editor restarts: cetas-acp restores the decision slot on every new session, keeps it selected (decision off) when the provider is temporarily missing instead of silently switching backends, and tells you to switch with `/decision` once the provider returns.

## Run Ver.（cetas-run）

### Feats

- The built-in `cetas-about` manual now carries the exact `cetas-run` version, so asking the agent which version it runs answers with the real distribution version.

## 0.10.9 (2026-10-23)

## Bun Ver.（cetas-bun）

### Feats

- Board tickets can now be executed: start a Ready ticket from the Board and Cetas runs it as a background worker, moves it through Running to In review, and files the outcome in the Board Inbox. One action starts the next Ready ticket, and finished results can be dismissed once handled.
- Pending questions can be answered with the new `/questions` command and `/answer`: both open the same reply panel used for live asks, with the correct input, confirm, or option controls. `/board stop` closes all local Board servers.
- Background shell sessions are now available: a long-running command can be started with `bash` in the background and checked, waited on, or stopped with `bash_status`, `bash_wait`, and `bash_kill` instead of blocking the turn.
- PTC `run_code` now accepts a complete `.mbtx` program through `source` — including imports and `main` — in addition to the inline handler body, and gives a clear correction when both are supplied or when a function signature is sent as inline code.

### Fixes

- `/board` now serves the full interactive Board app from the Bun build instead of the earlier minimal snapshot page, so the same Kanban, ticket inbox, and ticket controls work in packaged installs.
- OpenCode Zen responses that send explicit null `tool_calls` or null reasoning fields no longer fail with a response parse error; null is treated as an absent field and the normal fallback still applies.
- The PTC status segment now shows `Hybrid` instead of `PTC: Hybrid`, matching the other mode labels.

## 0.10.8 (2026-10-23)

## General

### Feats

- OpenCode Go can now be connected with an OpenCode Console account through a browser device-flow login, so you no longer need to create a personal API key. Console grants refresh automatically, route requests to the correct organization, and work alongside the existing API-key login.
- OpenCode account credentials now work consistently across the Go and Zen wires, including organization-scoped requests and the correct authentication scheme for each wire.

## Bun Ver.（cetas-bun）

### Feats

- Start a controlled workflow from one high-level goal with `/workflow <goal>`: Cetas runs real planning, shows the proposed task graph, and asks you to approve the graph and execution scope separately. After approval, one action prepares the authorized tasks and runs the next bounded execution wave without silently marking work complete.
- `/workflow` and `/board` are now normal, discoverable commands even when workflows are disabled. Enabling workflows asks for confirmation and preserves your existing provider and model settings.
- `/board` opens a token-protected live Kanban on localhost, showing tasks, dependencies, attempts and active agents across seven lanes, with pause, stop and cancel controls. The board shuts down with Cetas.
- `/ptc` opens an interactive mode picker for PTC Only, Hybrid or Direct, shows the active mode in the status bar, and applies the change from the next turn.
- Choice-based questions now include an “Other answer” option that opens a free-text field, so you are never trapped between the model’s suggested choices.

### Fixes

- Startup no longer waits for stored MCP OAuth credentials. Token refresh and server probes run in the background, so an expired credential can no longer delay the first turn by up to 30 seconds; MCP tools appear as soon as their probes finish.
- The protected Node distribution keeps tagged-template syntax intact and falls back safely when Bun’s whitespace pass rejects otherwise valid output, so the packaged CLI no longer ships broken JavaScript.
- `/workflow <goal>` now forwards the goal correctly, dispatches through the canonical workflow command, reports Board failures as command errors instead of crashing, and closes the local Board server on shutdown.
- Shell commands now enforce a hard deadline — 5 minutes by default, configurable up to 1 hour — stop the command and its child processes on timeout, and keep streamed output bounded. Hung children and output floods can no longer stall the app or exhaust memory.
- Model metadata now falls back to an alternate mirror when models.dev is unreachable, so context limits and capabilities still resolve on restricted networks.
- OpenCode streaming and response errors now name the exact provider plane (Zen or Go), making failures easier to diagnose.

## ACP Ver.（cetas-acp）

### Fixes

- Shell commands now enforce a hard deadline — 5 minutes by default, configurable up to 1 hour — stop the command and its child processes on timeout, and keep streamed output bounded. A stuck command or output flood can no longer stall an ACP session or exhaust memory.
- Shell output is decoded correctly when a UTF-8 character spans multiple pipe reads, and timeout failures now return a clear diagnostic instead of garbled or truncated output.
- Model metadata now falls back to an alternate mirror when models.dev is unreachable, so context limits and capabilities still resolve on restricted networks.
- OpenCode streaming and response errors now name the exact provider plane (Zen or Go), making failures easier to diagnose.

## Run Ver.（cetas-run）

### Feats

- Choice-based questions now include an “Other answer” option that opens a free-text field, so you can answer beyond the model’s suggested choices.

### Fixes

- Shell commands now enforce a hard deadline — 5 minutes by default, configurable up to 1 hour — stop the command and its child processes on timeout, and keep streamed output bounded. A stuck command or output flood can no longer stall a one-shot run or exhaust memory.
- Shell output is decoded correctly when a UTF-8 character spans multiple pipe reads, and timeout failures now return a clear diagnostic instead of garbled or truncated output.
- Model metadata now falls back to an alternate mirror when models.dev is unreachable, so context limits and capabilities still resolve on restricted networks.
- OpenCode streaming and response errors now name the exact provider plane (Zen or Go), making failures easier to diagnose.

## 0.10.7 (2026-10-22)

### Added
- [cetas-js] feat(cetas-js): register shared renderer for bash and powershell (8464e36)

## 0.10.6 (2026-10-21)

## Bun Ver.（cetas-bun）

### Feats

- Goal mode: run one persistent objective across many turns with `/goal <objective>`, `/goal status`, `/goal pause` and `/goal resume`. Runs are bounded (20 turns by default), progress is tracked in a plan you can inspect, and completion must be independently verified — Cetas asks you to approve the claimed result, a rejected claim sends the agent back to work within its remaining budget, and an unverified claim never counts as success. Pausing stores a versioned checkpoint tied to the session and its transcript; after a restart, resume restores that checkpoint only when the session and transcript still match, and otherwise refuses instead of repeating side effects.
- Session model restore: switching to or resuming a session now restores that session's model and effort immediately — the status bar updates and the transcript confirms it — instead of waiting for your first message. A `/model` choice you make afterwards is never overridden, and unavailable saved selections fall back with a clear warning.
- Images reach DeepSeek: with `image_input: true` on a vision-capable DeepSeek model, `@image` mentions are sent as real image parts and the model is advertised as accepting images. Without the opt-in the image is still announced to the model as an explicit placeholder instead of disappearing silently.
- DeepSeek V4 / V4.1 prompt profile: set `prompt_profile` so prompts are rendered the way DeepSeek's official recipe expects instead of guessing from a model alias, with reasoning effort names normalized to the values that profile uses (`minimal`/`low` → `low`, `medium`/`high`/`xhigh` → `high`, `max`/`ultra` → `max`).
- The grep tool accepts an opt-in regular expression (`regex: true`) for alternation, character classes, anchors and quantifiers, on both the ripgrep and built-in engines; literal search stays the default and an invalid pattern fails the search loudly.

### Fixes

- First launch is now race-free: a complete minimal settings file is published atomically, so two simultaneous launches cannot clobber each other and no half-written or empty file is ever read. An existing malformed file is reported to you instead of being silently replaced.
- Long DeepSeek conversations can be compacted without breaking the cached prompt prefix — compaction replays the same message head and tool declarations and accounts for earlier reasoning, so summaries stay faithful and cache hits survive; a stray tool call is rejected instead of being stored as the summary.
- Cancelling a turn now actually stops a running PowerShell command on Windows (graceful interrupt, then hard kill), and output collection is bounded so a lingering child process can no longer hang the turn.
- Changing reasoning effort no longer prints the model status twice.
- Workflow observation fixes: pause/stop/cancel acknowledgements refresh settlement instead of admitting new work, cancellation, timeout and transport failures produce distinct diagnostics, and a failed status read is surfaced once without retrying anything.

## ACP Ver.（cetas-acp）

### Feats

- Images attached in your editor now reach vision-capable DeepSeek models once `image_input` is enabled — they are sent as real image parts instead of being reduced to placeholders.
- DeepSeek V4 / V4.1 prompt profile: `prompt_profile` renders prompts per DeepSeek's official recipe rather than inferring a version from the model alias, and normalizes reasoning effort names to that profile's values.
- The grep tool accepts an opt-in regular expression (`regex: true`); literal search remains the default and invalid patterns fail clearly.

### Fixes

- DeepSeek compaction preserves the cached prompt prefix (same message head and tool declarations, earlier reasoning accounted for), so long editor sessions stay coherent and fast; a tool-call response is rejected rather than stored as a summary.
- Cancelling a turn stops a running PowerShell command on Windows, and output collection can no longer stall on a lingering child process.

## Run Ver.（cetas-run）

### Feats

- DeepSeek V4 / V4.1 prompt profile: `prompt_profile` renders prompts per DeepSeek's official recipe instead of inferring a version from the model alias, with reasoning effort names normalized to that profile's values.
- The grep tool accepts an opt-in regular expression (`regex: true`) for scripted investigations; literal search remains the default and invalid patterns fail clearly.

### Fixes

- DeepSeek compaction preserves the cached prompt prefix and earlier reasoning, so continuing a session by id stays coherent and fast.
- Cancelling an invocation now stops a running PowerShell command on Windows (interrupt, then hard kill) and bounds output collection, so a stuck or lingering child process no longer hangs automation.

## 0.10.5 (2026-10-20)

## General

### Feats

- Every Cetas client now gives DeepSeek models conservative reasoning safeguards by default.
- DeepSeek now helps break tool-call loops: after the same tool call is repeated three times in one user turn, the next request carries a convergence instruction asking the model to check whether another call would produce new evidence, then either change approach or return a supported partial answer.

### Fixes

- DeepSeek requests that include tools now replay assistant reasoning from earlier turns as required, fixing API rejections and failed follow-up tool calls that previously occurred when a plain assistant turn omitted its reasoning.
- Empty non-streaming DeepSeek replies cut off by the length limit no longer appear as blank answers: Cetas retries once at low effort and reports a warning, while partial answers and tool calls are never retried.
- The streaming repetition guard no longer fires after a stream has already completed, and long reasoning no longer overflows its span comparison.
- Reasoning ceiling and recovery settings now survive credential changes, effort changes and model-catalog rebuilds, so a configured protection cannot silently disappear mid-session.

## Bun Ver.（cetas-bun）

### Feats

- Controlled multi-agent workflows are now available as an opt-in feature. Enable `workflow.enabled` in `~/.cetas/settings.json`, then use `/workflow`: Cetas proposes a bounded task graph from your requirement, shows a DAG preview, and runs eligible tasks in parallel waves. You separately approve the graph, the execution scope, each task's trusted input and each wave, so planning cannot silently expand into execution.
- Long workflow runs stay controllable. `/board.workflow.status` and `/board.workflow.preview` report the live graph, budgets, attempts and blockers, while `pause`, `resume`, `stop` and `cancel` remain reachable even while another command or an execution wave is occupying the session.
- Workflows are isolated and predictable: each workflow pins its model and reasoning effort when first composed, planning agents have no tools, execution agents receive freshly scoped read/search/write/edit/shell tools under the current permission policy, and a successful agent reply never marks a task Done by itself.
- Workflow state is durable per workspace under `~/.cetas/board/`, with an append-only audit trail, execution identity journal and a single-writer lock. After a restart you can inspect the graph and identities read-only; Cetas never silently re-approves, resumes or replays work.
- Programmatic tool calling now cooperates with your normal toolset. The model can choose `run_code` when batching several predictable file, search or shell operations saves tokens and round trips, while native, Pi and MCP tools remain available for ordinary calls.
- `run_code` keeps full schemas for the core coding tools, while less-used capabilities are reduced to concise names and descriptions, cutting the batching prompt's size without losing precision on coding work.
- Delegation is now the `subagent` tool, and its run card shows the delegated task while the call is still forming, followed by live child progress. The card also surfaces the spawn settings that matter — kind, model and effort, background, resume, timeout, and tool or skill counts — and expanding it reveals the full task.

### Fixes

- Enabling programmatic tool calling no longer replaces or hides the normal tool surface: native, Pi and MCP tools stay visible and direct calls keep their usual dispatch.
- Nested calls inside `run_code` are checked individually by the permission policy and can be vetoed by plan mode after argument rewrites; the transport itself no longer requires a second blanket approval.
- Cancelling a turn now cancels an in-flight `run_code` and its nested calls instead of leaving orphaned work running behind the UI.
- Assistant messages produced by a child agent now appear reliably in the live transcript; previously they could be dropped when a child emitted a batched event.
- The terminal interface now follows the foreground and background colors your terminal actually advertises. Prompt and transcript surfaces choose readable light or dark tints, and when the terminal does not advertise colors they stay transparent instead of forcing a dark box onto a light terminal.
- Modal overlays preserve true terminal faint styling, so the veil no longer flattens dimmed content into a flat muted color.

## 0.10.4 (2026-10-19)

## Bun Ver.（cetas-bun）

### Feats

- Ask Cetas to solve a task with code: the built-in `run_code` tool lets the agent run MoonBit programs inside the current session — either a short inline body or a complete `.mbtx` program using the official MBTX SDK — with JSON input in, a JSON value out, cancellable execution and bounded output.
- Repeated code runs are fast: compiled programs are kept in a persistent per-program build cache (partitioned by MoonBit toolchain version), so later runs skip recompilation while each concurrent run executes its own private copy of the artifact instead of racing over a shared binary.
- `/status` now reports what your model manager actually knows: when a composed manager extension provides a status command, `/status` is routed to it (including Magpie gateway status), so provider, quota and gateway facts come from the manager rather than a shell-side guess, with the local summary kept as the fallback when no manager is present.

### Fixes

- The setup snapshot now marks the model you actually selected as active instead of flagging the first entry in the model catalog; a saved selection that is no longer in the catalog stays visible as pending rather than being silently swapped for another model.

## 0.10.3 (2026-10-19)

### Added
- [cetas-js] feat: add tests for non-blocking ask shell flow and notify_user renderer (19f90d7)
- [cetas-js] feat: implement non-blocking question handling with notify_user tool (f01883d)
### Fixed
- [cetas-js] fix(cetas): preserve default providers backoff and balance callback (df3295e)
- [cetas-js] fix(cetas): correct recovery constructor and ten-minute probe cap (5139b88)
- [cetas-js] fix(cetas): use short probing for Magpie transient gateway recovery (6ae71e2)

## 0.10.2 (2026-10-17)

## Bun Ver.（cetas-bun）

### Feats
- Sessions now remember their model: resuming a conversation restores the exact model and reasoning effort that produced it, so a session no longer silently falls back to your global default after a restart.
- Model selections are persisted as versioned, owner-qualified records, so multiple managers (built-in and Magpie) keep separate selections without overwriting each other, and records written by an older manager keep working with that same manager.
- The statusbar now shows how full your context window is — measured or estimated tokens used against the model's window, with a percentage. Estimates carry a `~` marker, and missing readings show `?` instead of a misleading zero.
- The statusbar header now displays the current git branch in a soft pastel green, so you always know which checkout you are working in.

### Fixes
- Copying selected transcript text now works over SSH and inside terminal multiplexers: the terminal clipboard transport (OSC 52) is used when no native clipboard is available, native clipboards without write support no longer abort the copy, and you get a single clear notice only when no clipboard transport exists at all.
- Autocomplete suggestions now expand to the full available width, so long `@`-paths and commands are no longer truncated to a narrow column, and the highlighted entry is emphasized across its entire row — the current selection is instantly visible.
- Statusbar secondary rows were re-ordered for readability: the active permission mode leads, provider quota windows (including weekly/monthly) are grouped together, and remaining metrics keep their reported priority order.
- The average speed in the statusbar is now a true weighted rate (total output tokens over total decode time), so bursts of short tool-call rounds no longer inflate the reported average.
- Live activity entries no longer show a redundant "1" next to running agents (now `⚡ agent(name) · ...`).

## 0.10.1 (2026-10-17)

## Bun Ver.（cetas-bun）

### Fixes
- Mouse text selection in the transcript works reliably again: dragging highlights exactly the characters you select — the highlight stays visible even inside colored Markdown output — and releasing copies precisely that range instead of the whole message.
- Finishing a selection now always clears the highlight and copies your text, including on terminals that report the mouse release without a button code, and a plain click no longer leaves inverse-video residue behind or copies anything.
- Backwards and multi-line drags copy the selected lines in the right order, and drags spanning several messages still copy each message in full — even parts currently scrolled out of the virtualized viewport — without rendering off-screen history just to complete the copy.

## 0.10.0 (2026-10-17)

## General

## Bun Ver.（cetas-bun）

### Feats
- Long sessions stay fast at any size: the transcript is now rendered through a virtual engine, so scrolling, resizing, and modal overlays only process what fits on your screen instead of the whole history — 10k-message sessions scroll smoothly, resume and rewind are instant, streaming Markdown renders incrementally (only the active block re-renders), and leaving the fullscreen view keeps your normal terminal scrollback intact.
- Search now covers the entire session, including text inside collapsed or off-screen tool results, with wraparound navigation and exact-match highlighting; select text with the mouse across message boundaries and copy exactly what you selected, or copy a message's source text directly.
- A new responsive two-tier statusbar leads with your model and reasoning effort plus the active model manager, surfaces rate-limit/reset and quota information right after, and keeps git branch and context usage in view — readable at any terminal width and colored from your terminal's own palette.
- Subagent runs, their pending questions, wakeups, and waiting results now share one compact Live Activities region — when a child agent asks you something, its question appears right there instead of scrolling away in the stream.
- Cetas now reports its agent state (working, waiting for your answer, waiting for authentication) to compatible terminals, so you can tell the agent is blocked on you without watching the session.
- New `/manager` command switches between the built-in providers and the Magpie gateway: switching atomically recomposes the agent with rollback on failure, each manager keeps its own model and reasoning-effort selection, and `/status` names the active manager. Magpie setup lives entirely in `/login` — local or remote gateway address typed in plain sight with only the key masked, credentials verified before anything is saved, and the model picker grouped by gateway owner with selectable routing groups.
- The `/quota` overlay shows each provider's real quota windows — plan, account, balance, per-window usage, pool sharing, unlimited flags, and reset times — and refreshes only on request via `/quota refresh`, with cached readings marked as such instead of posing as live data.
- Resuming a session restores the model and reasoning effort that produced its last turn, so picking up earlier work no longer silently runs on whatever model happens to be selected.
- Delegated subagents are manager-aware: the manager's model catalog is loaded at startup, so child agents work immediately after you switch to Magpie.

### Fixes
- Search no longer skips matches near the transcript ends (wraparound corrected) and highlights only exact visible matches.
- Your scroll position no longer jumps when earlier messages resize or their heights are re-measured, and copy failures are reported instead of failing silently.
- Exiting the fullscreen transcript no longer replays the session into your main scrollback.
- Dismissing the quota overlay releases the input lock, so the UI no longer stays stuck behind a modal veil.
- Codex WebSocket connections now deliver a usage-limit notice that arrives just before the connection closes as a proper rate-limit message instead of a generic transport error.
- Shell commands run in their own process group: cancelling a command or quitting kills the whole child tree instead of leaving orphaned background processes, and fatal shell failures surface cleanly instead of hanging the UI.
- The delegation tool is now offered only when a runnable child runner binary actually exists, so the agent never picks a delegate command that cannot start.
- Model-manager switching is safe under pressure: turns and commands are blocked during the handoff, gateway configuration is serialized against running turns, concurrent switches are guarded, a failed Magpie setup rolls back completely, and Magpie reconnects correctly after switching managers away and back.
- Model-group labels supplied by a gateway are sanitized before display.
- Image attachments now work when the terminal runs through Node (npm install).
- Local commands like `/quota` and `/status` appear in slash autocomplete again.
- The autocomplete popup renders above the composer with a background derived from your terminal's actual colors, and extreme terminal widths no longer break redraws.

## 0.9.1 (2026-10-15)

## Bun Ver.（cetas-bun）

### Feats
- Subagent questions now surface right in the stream: when a spawned subagent parks a question, its run card shows exactly what it asks — free-text input, a yes/no confirm, or a select with options — and the run status switches to "? waiting your answer", so you can tell a child is blocked on you rather than still working.
- Your replies to subagents are now on the record: each answer produces a dedicated transcript entry showing the question and the submitted answer side by side, both live and when replaying a saved session, replacing the bare "answer accepted" line.

### Fixes
- Fatal host faults no longer leave a frozen terminal: cetas now restores the terminal, releases background resources, logs full crash details, and exits with a clear pointer to restart and pick up your persisted session — instead of lingering as an unresponsive screen; cleanup failures during a crash no longer cascade, and a broken output pipe (e.g. a detached terminal) is detected instead of erroring repeatedly.

## 0.9.0 (2026-10-15)

### Added
- add opencode-go provider and update related tests and imports (37e52d4)
- implement version check and update notification system (f69e71c)

## 0.8.1 (2026-10-12)

## General

### Feats
- Cetas now knows each model's real context window instead of guessing: capacity is resolved from your own `context_window` setting, provider discovery, the on-disk provider cache, or a models.dev lookup cached to `~/.cetas/models_dev.json`. Auto-compact and context budgeting now run against the true window — previously, models whose providers didn't report a window had none — and an unverified 500k fallback is now labeled as such instead of being shown as fact.
- DeepSeek, Z.AI, and OpenAI-compatible provider catalogs now ship context-window metadata for their models.

### Fixes
- A `settings.json` saved with a leading UTF-8 BOM no longer breaks startup or model selection.

## Bun Ver.（cetas-bun）

### Feats
- `/model` and `/status` show the active model's context window together with where it came from (configured, provider, cache, or unverified fallback), and metadata refreshes automatically at startup, after login, and when you open the model picker — so newly released models get real windows without reinstalling.
- Subagents inherit the same model metadata, so delegated swarms budget and report context against the correct window too.
- Plan mode is smarter and safer: shell commands are judged by where they write, not by a command-name denylist. Scratch work into `/tmp` and `/dev/null` (including `tee`, `touch`, `cp`, even `rm -rf` of `/tmp` paths) runs freely while planning, workspace `.md` notes stay writable, and any command that could write outside those areas is stopped before it runs.

### Fixes
- A missing `~/.cetas/settings.json` now starts you with first-use defaults instead of failing, so fresh installs and Windows-edited settings files both load cleanly.
- The welcome banner's logo no longer renders with misaligned rows.

## ACP Ver.（cetas-acp）

### Feats
- Context usage reported to your editor is now computed from the active model's real context window (provider-reported, cached, models.dev, or your configured override), instead of only appearing when discovery happened to include one.
- Plan mode gets the same write-destination analysis: investigation commands run freely, scratch writes to `/tmp` and `/dev/null` are allowed while planning, and anything that could modify files outside the writable areas is rejected.

## Run Ver.（cetas-run）

### Feats
- One-shot runs now budget context against each model's true context window, so auto-compact engages at the right point even for models whose providers don't report capacity.
- Known context windows survive offline restarts by being restored from the provider cache.

## 0.8.0 (2026-10-12)

### Added
- [cetas-js] feat: add unit and e2e test scripts to package.json (d8da924)
- [cetas-js] feat: add test channel runner for unit and e2e tests (19e69b6)
- [cetas-js] feat: refresh Cetas identity, README, and terminal welcome (3eac969)
- [cetas-js] feat: remove unused (7e0ea99)
- [cetas-js] feat: remove unused imports from moon.pkg and update subproject commit reference (8dbeb26)
- [cetas-js] feat: update wakeup header terminology to reflect pending delivery status (a77d306)

## 0.7.0 (2026-09-30)

## General

### Feats
- Your saved model choice is never silently swapped anymore.

## Bun Ver.（cetas-bun）

### Feats
- Configure your subagent fleet from `~/.cetas/settings.json`: a new optional `subagent` section lets you restrict which model slots and reasoning efforts subagents may use, pin a default subagent model, and cap swarm size, per-group/global concurrency, timeouts, and spawn budget.
- Subagent kinds can now pin a reasoning effort.
- OpenAI/Codex model lists now survive offline.

### Fixes
- Switching models while a rate-limit retry is scheduled now cancels the stale follow-up before the switch, so an outdated retry can no longer fire after you've moved to another model or duplicate your requests.

## ACP Ver.（cetas-acp）

### Feats
- Startup now honors your saved model.
- OpenAI/Codex catalogs rebuild from cached discovery records, so the full model list — not just a single static model — is available offline after a prior refresh.

### Fixes
- Every ACP session now holds its own agent task scope for its whole lifetime, so background and delegated work can be submitted from the first prompt and is shut down cleanly when the session retires.

## Run Ver.（cetas-run）

### Feats
- Log in from the terminal: `cetas-run --login [provider]` runs the full authentication flow standalone, saves credentials to the shared Cetas home, refreshes the model catalog, and lets you pick your initial model (auto-selected when only one is available). Wasm builds get clear guidance to log in via Cetas `/login` with the same home.
- cetas-run is now published on Mooncakes: run one-shot turns anywhere with `moonx colmugx/cetas-run -- --yolo -- "your task"` — built for scripts, CI pipelines, agent swarms, and sandboxed MoonX execution.
- Friendlier first run: startup creates a minimal `~/.cetas/settings.json` with an onboarding guide, full `--help` output, and credentials shared with Cetas — if you're already logged in elsewhere, just retry your task.

### Fixes
- Reliable process exit codes on both native and wasm builds.

## 0.6.0 (2026-09-29)

## Bun Ver.（cetas-js/cetas-bun）

### Feats
- Rich media attachments are now first-class.
- Compaction and token estimation understand attachments, so context budgeting stays accurate in media-heavy sessions.
- Subagents report detailed background-task exit states, making parallel delegated work easier to trust and debug.
- Provider login is hardened with Node.js crypto-backed UUID generation.
- The lazytools gateway now tracks usage across every terminal tool event for more accurate stats.
- The default permission mode is now `yolo` — fewer approval interruptions out of the box.

### Fixes
- Responses-API providers encode assistant content as `output_text` for maximum compatibility.
- Turn status is correctly restored after running a mid-turn command, and approvals are now scope-honest.
- Image array validation failures no longer surface as spurious protocol errors in the event bridge.
- Permission grants are labeled by scope with an explicit tool-level grant option.

## ACP Ver.（cetas-acp）

### Feats
- Tool outcomes can now carry attachments through the ACP bridge, so editors like Zed receive full-fidelity results.
- Permission requests carry scopes, giving clients finer-grained approval decisions.
- Transient model failures are automatically classified and retried.
- Compaction and token estimation handle messages with attachments.
- The default permission mode is now `yolo`.

### Fixes
- Permission session grants are labeled by scope, with an explicit tool-level grant for precise control.

## Run Ver.（cetas-run）

### Feats
- One-shot session transcripts (JSONL) support media attachments end-to-end.
- Transient model failures are automatically classified and retried, keeping scripted runs resilient.
- Compaction and token estimation account for messages with attachments.
- Delegated work via herdr honors a `parent_yolo` setting, so sub-tasks inherit your autonomy preference.
- The default permission mode is now `yolo`.


## Memoh Ver.（cetas-memoh）

### Feats
- ACP session controls now expose model and reasoning-effort selection, with runtime context-window accounting refreshed when the active model changes.
- `cetas-memoh` is now part of the Cetas release train, with versioned Linux, macOS, and Windows binaries included in release artifacts.

### Fixes
- User cancellations now settle as ACP `cancelled` instead of being reported as application failures.
- Failed session construction now closes the Memoh Tools MCP bridge before returning, avoiding leaked connections during startup failures.

## 0.5.3 (2026-09-27)

## Bun Ver.（cetas-js/cetas-bun）

## ACP Ver.（cetas-acp）

## Run Ver.（cetas-run）

## 0.5.3 (2026-09-27)

## Bun Ver.（cetas-js/cetas-bun）

## ACP Ver.（cetas-acp）

## Run Ver.（cetas-run）

## 0.5.2 (2026-09-27)

## Bun Ver.（cetas-js/cetas-bun）

### Feats
- Plan reviews no longer expire.
- plan results now keep the full plan readable after your decision — expand with ctrl+o to re-read the accepted, revised, or dismissed plan.
- Sessions get stable, metadata-backed automatic titles.

### Fixes
- Plans are saved to disk the moment they are submitted, so a dismissed, failed, or unanswered review still leaves the plan text on file instead of losing it.

## ACP Ver.（cetas-acp）

### Feats
- Session titles advertised to ACP clients are now metadata-backed and stable — user-chosen names take priority, older sessions fall back to a legacy first-message title.
- Plan mode is now a proper write gate: its enter/exit tools bypass the permission prompt, while all other tools keep flowing through the permission policy.

### Fixes
- Plans are saved to disk the moment they are submitted, so a dismissed, failed, or unanswered review still leaves the plan text on file instead of losing it.

## 0.5.1 (2026-09-26)

## Bun Ver.（cetas-bun）

### Feats
- Subagents are now owned by the Bun runtime.

### Fixes
- Child agent tool construction no longer leaks the wrong filesystem.
- Memory extension MCP calls now report detailed, phase-aware failure reasons.

## ACP Ver.（cetas-acp）

### Feats
- Dynamic context window updates.

### Fixes
- The subagent tool is no longer part of the ACP tool catalog.
- Memory extension MCP calls now report detailed, phase-aware failure reasons.

## 0.5.0 (2026-09-25)

## Bun Ver.（cetas-js/cetas-bun）

### Feats
- Isolated subagents are now wired into the JS/Bun host.
- Plan mode gets first-class UI.
- Codex OAuth credentials are renewed automatically at load time.
- Shell execution is fully cancellable with graceful termination followed by a hard-kill fallback, and shell runtime handling across the host is more robust.
- Zcode delegation now supports background execution with proper task management, so long delegations keep the conversation responsive.
- The stats panel now reports token accounting and cache-aware usage, distinguishing unknown from genuinely zero cache telemetry.
- Skills get semantic search.
- The model now adjusts reasoning effort per call via a DecisionPort, spending tokens where they matter.
- AskQuestion gains lifecycle management with an optional UI port for cleaner interactive prompts.
- Tool outputs across the built-in toolkit are now bounded and compacted, dramatically cutting context token waste per turn.
- MCP external tool schemas and results, memory tool outputs, and deferred-tool payloads are capped and compacted, keeping long sessions lean.
- Subagents gained a global concurrency cap and a fresh per-run spawn budget, so long-lived sessions never silently exhaust their delegation allowance.
- Prompt-cache rejection state is now shared and preserved across rebuilds, protecting your cache hit rates.
- The herdr channel adds regex matching and background delegation, with restored resident delegation strategy and deferred-tool guidance.
- The lazy-tools meta layer keeps stable manifest surfaces and falls back to semantic DecisionPort matching when tool discovery is ambiguous.
- OpenCode Zen model retrieval is now async and more reliable for live catalog refreshes.

### Fixes
- Invalid CLI flag values now fail fast with clear error messages instead of confusing failures, and session management is steadier.
- Oversized prompt-cache keys are now hashed instead of rejected outright.

## ACP Ver.（cetas-acp）

### Feats
- Isolated subagents are now available over ACP.
- A new `auto` permission mode joins readonly / workspace_write / interactive / yolo, letting a DecisionPort preapprove safe actions automatically.
- Agents now stream thought chunks to the client immediately via `push_agent_thought_chunk`, so you see reasoning as it happens.
- Session renaming lands as a slash command: `/name <title>` retitles the persisted session and pushes the new name straight to your client.
- Codex OAuth credentials renew automatically at load time, with a full OAuth transport for the OpenAI provider.
- Shell execution is fully cancellable with graceful termination and a hard-kill fallback.
- Zcode delegation supports background execution with proper task management.
- Skills get semantic search, and the lazy-tools layer falls back to semantic matching for tool discovery.
- The model adjusts reasoning effort per call via a DecisionPort; `auto` permission mode is backed by tightened DecisionPort preapproval.
- AskQuestion gains lifecycle management with an optional UI port.
- Built-in tool outputs are bounded and compacted, along with MCP schemas and memory tool results, to cut context waste.
- Subagents gained a global concurrency cap and a fresh per-run spawn budget per turn.
- Prompt-cache rejection state is shared and preserved for providers.
- User request lifecycle events are now ingested into the ACP bridge for more accurate client state.

### Fixes
- Cancelled turns no longer leave the model transport in a broken state; cancellation handling is cleaner end to end.

## Run Ver.（cetas-run）

### Feats
- cetas-run is now part of the release pipeline and published.
- A new `auto` permission mode is available via `--permission auto` (and `--yolo` remains for unattended runs), backed by DecisionPort preapproval.
- Shell execution is fully cancellable with graceful termination and a hard-kill fallback.
- Skills get semantic search, and the lazy-tools layer falls back to semantic matching for tool discovery.
- The model adjusts reasoning effort per call via a DecisionPort.
- AskQuestion gains lifecycle management for cleaner interactive prompts.
- Prompt-cache rejection state is shared and preserved for Kimi, OpenRouter, and OpenAI-compatible providers.

### Fixes
- Invalid CLI flag values now produce clear error messages instead of silent misbehavior, and run-loop session handling is more reliable.

## 0.4.0 (2026-09-11)

## Bun Ver.（cetas-js/cetas-bun）

### Feats
- Model picker now shows provider quota windows and per-model pricing badges so you can pick the right model before spending tokens.
- Faster app launch when opening the model picker.
- New `/model quick-pick` command groups models by usage limits, balance, and other quick figures for one-keystroke switching.
- DeepSeek models gained explicit reasoning-effort levels and built-in pricing information.
- Herd progress reporting now runs on a dedicated delegate with a full JS backend channel for the bun terminal UI.
- The rtk command wrapper gained dedicated rewriter backends per runtime for more reliable command execution.

## ACP Ver.（cetas-acp）

### Feats
- DeepSeek models gained explicit reasoning-effort levels and built-in pricing information.

## Run Ver.（cetas-run）

### Feats
- Herd progress reporting now runs on a dedicated delegate with a native backend channel for one-shot runs.

## 0.3.2 (2026-09-09)

## Bun Ver.（cetas-js/cetas-bun）

### Feats

- Update package configurations to support native and JS targets

### Fixes

- Update posoco dependency to 0.15.0 and clean up unused imports in extensions
- Remove strconv dependency and fix string conversion in the Kimi extension usage reporting
- Update DeepSeek reasoning effort values to include `low` and improve model catalog handling

## ACP Ver.（cetas-acp）

### Feats

- Update package configurations to support native and JS targets

### Fixes

- Update posoco dependency to 0.15.0 and clean up unused imports in extensions
- Wrap libc system calls in a prefixed shim to avoid prototype collisions on Linux
- Remove strconv dependency and fix string conversion in the Kimi extension usage reporting
- Update DeepSeek reasoning effort values to include `low` and improve model catalog handling

## Run Ver.（cetas-run）

### Feats

- Rework output handling with StreamPrinter for clean stdout output
- Update package configurations to support native and JS targets

### Fixes

- Update posoco dependency to 0.15.0 and clean up unused imports in extensions
- Wrap libc system calls in a prefixed shim to avoid prototype collisions on Linux
- Remove strconv dependency and fix string conversion in the Kimi extension usage reporting
- Update DeepSeek reasoning effort values to include `low` and improve model catalog handling

## 0.3.1 (2026-09-09)

## Bun Ver.（cetas-js/cetas-bun）

### Feats
- Session titles are now generated and managed, with improved in-app session management
- New `posoco-ext-stats` extension providing speed metrics and cache accounting
- Zcode task delegation and tool integration
- Companion path resolution, session renaming, and project directory handling in session management
- Enhanced context state management with a new ctx segment
- Cross-platform user home resolution for more reliable configuration paths

### Fixes
- Stats reporting improvements
- MCP user `mcp.json` path handling on the user level
- More informative webfetch error messages for blocked hosts
- Statusbar now correctly reports valued segments
- Improved prompt cache key handling for better cache reuse

## ACP Ver.（cetas-acp）

### Feats
- Per-project session storage and slash command handling
- Session info updates surfaced to clients
- Zcode task delegation and tool integration
- Companion path resolution, session renaming, and project directory handling in session management
- Enhanced context state management with a new ctx segment
- Cross-platform user home resolution for more reliable configuration paths

### Fixes
- MCP user `mcp.json` path handling on the user level
- More informative webfetch error messages for blocked hosts
- Improved prompt cache key handling for better cache reuse
- More robust SSE stream processing and error handling for responses-based models

## Run Ver.（cetas-run）

### Feats
- Enhanced JsonlObserver and TraceObserver for improved event streaming
- Enhanced context state management with a new ctx segment
- Cross-platform user home resolution for more reliable configuration paths

### Fixes
- MCP user `mcp.json` path handling on the user level
- More informative webfetch error messages for blocked hosts
- Improved prompt cache key handling for better cache reuse
