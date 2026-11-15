# Cetas Malphite — Implementation Plan

Malphite is the opt-in, local-first network of Cetas runtimes and agents. Booting a trusted instance should make it discoverable without requiring cloud connectivity.

## Invariants
- One authoritative executor for each running session; many observing clients.
- Session identity differs from process identity, surface identity, and agent identity.
- No hidden cross-device sharing of prompts, tools, secrets, or files.
- A detached client never detaches another subscriber.
- A slow or disconnected client cannot indefinitely stall agent execution.
- Durable session history and transient runtime event streams are not interchangeable.

## Milestones
1. **M1: Event fanout.** Replace the console EventHub's single-client assumption with independent subscription tokens. Preserve the native/desktop legacy sink; update WebSocket lifecycle and add two-client tests.
2. **M2: Attach, snapshot, replay.** Add per-client workspace/session selection; stable runtime epoch/cursor; snapshot+subscribe handoff without missing events; reconnect/gap handling.
3. **M3: Session authority.** Single writer per session, process-scoped ownership and arbitration of prompt/abort/approval. Local IPC (Unix domain socket / Windows named pipe). Avoid two agents writing one JSONL.
4. **M4: Host integration.** Go+Go, JS+JS, Go+JS (and Web) clients attach to the same live owner. Preserve host-specific capabilities; do not silently replace a JS host with a Go host.
5. **M5: Atom discovery.** Stable device/atom identities, ephemeral process IDs, capability descriptions, liveness and revocation, local registry.
6. **M6: Malphite Relay.** Optional Cloudflare Worker / Durable Object signaling, paired device identity, outbound connections, end-to-end permissions. Local operation remains independent.
7. **M7: Fairy delegation.** Structured observation, task messaging, delegation, wait/cancel and scoped approvals; ACP/MCP/A2A adaptors as appropriate.

## M1 — Review checklist
- [x] Test two subscribers receive the same event in order.
- [x] Test unsubscribing A leaves B attached.
- [x] Preserve the native/desktop single-sink adapter.
- [x] WebSocket owns and disposes its own subscription token.
- [ ] Run MoonBit native tests, formatting, typechecking and end-to-end dual-WebSocket test.
- [ ] Confirm slow-subscriber backpressure semantics; no silent queue overflow.

## Out of scope for M1
This milestone does **not** provide cross-process session synchronization, durable replay, per-client session selection, Cloudflare infrastructure, or the Atom/Fairy runtime model. Those are separate milestones and must not be claimed as shipped.

## Relevant code
- `cetas-console/console/protocol.mbt`
- `cetas-console/console/runtime.mbt`
- `cetas-web/server/main.mbt`
- `cetas-js/src/app/`
- `cetas-go/native_bridge/`

## Verification commands (from Cetas repository root)
```sh
moon check --deny-warn --output-json
moon fmt --check
moon info
moon test --target native --output-json
```

The first user-visible end-to-end goal is **two independently launched Cetas clients observing the same live session without creating a second agent execution**. M1 is one necessary prerequisite, not the full goal.
