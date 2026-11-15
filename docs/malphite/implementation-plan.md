# Cetas — Local Multi-Surface and Agent Collaboration

This document separates **Cetas's built-in local capabilities** from the optional **Cetas Malphite relay**.

## Product boundaries

There are exactly two product names in this architecture:
- **Cetas**: the agent product across JS, Go, Web, Memoh and other surfaces. It must support local multi-surface sessions and local agent-to-agent collaboration independently of any relay.
- **Cetas Malphite**: a relay/network service that connects authorized, online Cetases across machines or networks. It reuses Cetas protocols; it is neither a prerequisite for local communication nor the host executing an agent.

**Atom** (one core, every surface) and **Fairy** (Cetas's experience/metaphor as a digital-world spirit) are product concepts, **not** runtime classes, peer roles, protocol types, nor parent/child agent identities. Do not mint `AtomRuntime`, `FairyWorker`, `atom_id`, or `fairy_id` based on those concepts.

## Non-negotiable invariants
- A live Session has **one executor**, potentially observed or controlled by several Surfaces.
- Two independently launched Cetases can communicate **locally without Malphite**, including when offline.
- Session, process, surface and peer identities are distinct. Durable workspace/bucket identity scopes session IDs.
- A detached or slow surface cannot interfere with another surface or stall the agent.
- Messages from another Cetas carry a verified identity, an explicit capability/permission scope, and untrusted content grading. No implicit permission escalation or remote tool execution.
- Malphite only adds cross-network discovery, authentication and routing/relay, never a second implementation of agent execution or local collaboration.

## Merge strategy — vertical, independently demonstrable slices

### Cetas M4: Local multi-surface (first product track)
1. **Event fanout** ([PR #151](https://github.com/colmugx/cetas/pull/151)): multiple independent subscribers; connection-local error and handshake events; legacy native compatibility.
2. **Per-surface attach**: attachment identifies workspace+session without changing another surface's selection; requested snapshot only reaches the attaching client.
3. **Consistent snapshot/replay**: one authoritative cursor+epoch, subscribe/snapshot high-water barrier, explicit replay gap, no silent drops.
4. **Local single-owner IPC**: Unix domain socket / Windows named pipe with local credentials; one Session executor, never two concurrent writers to JSONL.
5. **Host integration**: Go+Go, JS+JS, Go+JS; browser as one Surface. No arbitrary requirement that a JS-hosted agent migrate into a Go process.

Success demo: launch a second Cetas, select an existing Session and observe its real-time output, without starting a second agent.

### Cetas M7: Local peer communication (parallel product track)
1. Discover currently running local Cetases; verify same-user local peer identity and liveness.
2. `peer.list`, `peer.inspect` (read-only description/capabilities).
3. `peer.send` (message delivery), `peer.ask` (bounded correlated request/reply) with explicit busy/queue semantics.
4. `peer.delegate`, `task.status`, `task.cancel`; reuse existing Cetas subagent/Board facilities rather than inventing a Fairy execution type.
5. Scoped approval, trust, cancellation and observability; JS and Go adapters.

Success demo: two separate local Cetases A and B; A can discover and ask B a question; B returns a correlated answer without losing its own Session context. No Malphite process required.

### Cetas Malphite: Later, independent network extension
- Connect authorized online Cetases across machines/networks by outbound relay connections.
- Presence, remote peer directory, authentication/pairing/revocation, route forwarding and connection recovery.
- Preserve the Cetas local message/Session protocol end-to-end, never duplicate task scheduling or session execution in the relay.
- No global open discovery: “online” means explicitly authorized members within the relevant trust scope.

## Current implementation scope
The current draft PR #151 is a Cetas local-multi-surface prerequisite, despite its historical `feat/malphite-event-fanout` branch name. It is **not** Malphite Relay.

### PR #151 completion checklist
- [x] EventHub supports multiple independent subscribers and legacy native sink.
- [x] Connection-local errors and ready events are unicast to their own WebSocket.
- [x] Session attach snapshot is unicast to the requesting surface.
- [x] Regression tests for subscriptions, out-of-band fanout, self-unsubscribe, connection-local isolation.
- [ ] Final GitHub CI checks green and MoonBit interface drift clean.
- [ ] Manual two-WebSocket smoke test, concurrent handling, slow-consumer behavior.
- [ ] Per-session workspace attach, gap-free replay, and actual cross-process owner (next M4 slices).

## Verification
```sh
moon check --deny-warn --output-json
moon fmt --check
moon info
moon test --target native --output-json
```

**Definition of completion:** a checked box for source code is not a claim that all local multi-surface behavior or any remote relay works. Keep user-visible milestones truthful and testable.
