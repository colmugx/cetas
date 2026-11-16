# Cetas local collaboration roadmap

## Product boundary
Cetas owns local multi-surface Session behavior and local Agent-to-Agent collaboration. Cetas Malphite is an optional network relay for authorized Cetas instances on different machines or networks. Neither M4 nor M7 requires Malphite.

Atom (one core, every surface) and Fairy (Cetas's spirit-like product experience) are product concepts, not protocol entities, runtime classes, or parent/child Agent roles.

## M4 — local multi-surface Session
1. Independent event subscriptions and connection-scoped control messages.
2. Per-surface attach to an explicit workspace and Session without mutating another surface's selection.
3. Snapshot/replay with a high-water cursor, runtime epoch, and explicit gap handling.
4. Local single-owner IPC (Unix domain socket / Windows named pipe) so one Session has one executor and one journal writer.
5. Acceptance across JS+JS, Go+Go, Go+JS, and Web surfaces.

Success: a second Cetas surface resumes an existing live Session and sees the same execution without composing a second Agent.

## M7 — local Agent collaboration
1. Local peer discovery and liveness.
2. Read-only peer listing and inspection.
3. Correlated ask/reply and asynchronous send.
4. Bounded task delegation, status and cancellation using existing Cetas subagent/Board facilities.
5. Permission-scoped execution, trust, audit and JS/Go adapters.

Success: two independently launched Cetases can discover and ask one another while offline and without Malphite.

## Cetas Malphite — optional remote extension
Pairing, authentication, remote presence, routing and relay across networks. Reuse Cetas's local protocols; do not move Agent execution or task scheduling into the relay.

## Current PR scope
PR #151 is the first M4 prerequisite: independent EventHub subscriptions and per-connection control frames. It does not yet implement per-surface workspace/session ownership, gap-free replay or cross-process single-owner execution.
