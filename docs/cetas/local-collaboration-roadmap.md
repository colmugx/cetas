# Cetas local collaboration and Malphite roadmap

## Product boundary

Cetas owns local multi-surface Session behavior and local Agent-to-Agent collaboration. Cetas Malphite is an optional network relay for explicitly paired Cetas instances on different machines or networks. Neither M4 nor M7 requires Malphite; both must work fully offline.

Atom (one core, every surface) and Fairy (Cetas's spirit-like product experience) are product concepts, not protocol entities, runtime classes, or parent/child Agent roles.

## M4 — local multi-surface Session

1. Independent EventHub subscriptions and connection-scoped control messages — implemented on main; historical PR #151 remains open and is superseded by M4.2/M4.3.
2. Per-Surface attachment to an explicit workspace and Session without mutating another Surface's selection — merged in PR #162.
3. Snapshot/replay continuity with per-Session high-water cursors, runtime epochs, and explicit gap handling — merged in PR #164.
4. Local single-owner IPC — OS owner lease from merged PR #166 and Unix wire protocol from merged PR #171; Windows named pipes, cross-host adapters, and single-writer end-to-end validation remain incomplete.
5. Acceptance across JS+JS, Go+Go, Go+JS, Web, and desktop surfaces.

Success: a second Cetas surface resumes an existing live Session and observes the same execution without composing a second Agent or creating a second journal writer.

M4.3 provides in-process event continuity, not cross-process ownership. M4.4 has native Go owner leasing and initial Unix transport building blocks, but does not yet provide cross-host shared execution or fully enforce single-writer ownership across JS, Go, and Web.

## M7 — local Agent collaboration

Tracked by [Issue #154](https://github.com/colmugx/cetas/issues/154).

1. Local peer registration, liveness, and same-user authenticated IPC endpoints.
2. Read-only `peer.list` and `peer.inspect`; no transcript or credential disclosure by default.
3. Correlated `peer.ask` / `peer.send`, timeout, backpressure, busy/refusal semantics, and inbox ownership.
4. Bounded `peer.delegate`, `task.status`, and `task.cancel` using existing Cetas subagent/Board abstractions.
5. Permission-scoped execution, trust boundaries, audit, and JS/Go host adapters.

Success: two independently launched Cetases can discover and ask one another while offline, without overwriting either user's active Session and without Malphite.

Incoming peer content is lower-trust data, never host/system instructions. The target Cetas instance owns execution, approvals, resource budgets, and cancellation.

## Cetas Malphite — optional remote extension

Malphite extends the local collaboration protocols across machine and network boundaries. It is a transport and relay plane, not an Agent runtime or task scheduler.

### Design invariants

- Explicit device pairing and revocable peer authorization; no implicit global discoverability.
- Mutually authenticated connections and a stable process/device identity distinct from Session IDs.
- End-to-end protected message envelopes as the target security model. The relay should route opaque payloads, not inspect prompts, transcripts, tool output, or provider credentials.
- Per-peer capabilities and scopes. A remote request is still authorized and executed by the target Cetas owner.
- Correlation IDs, deadlines/TTL, replay protection, idempotency, backpressure, and explicit offline/busy/refused/error outcomes.
- The relay never owns Session journals, Agent execution, tool approvals, task scheduling, or cancellation authority.
- Local M4/M7 behavior remains fully functional when Malphite is absent, unreachable, or disabled.

### Proposed implementation sequence

1. Stabilize and acceptance-test the local M4 and M7 protocols first.
2. Specify device identity, pairing, key rotation/revocation, capability grants, and the relay threat model.
3. Implement authenticated remote presence and opt-in routing.
4. Implement opaque relay envelopes with bounded queues, deadlines, and delivery acknowledgements.
5. Bridge remote `peer.ask` / `peer.send` over the same correlated local peer protocol.
6. Add bounded remote delegation only after target-side permissions, audit, budgets, and cancellation are proven locally.

### Acceptance

- Two explicitly paired Cetas instances can communicate across separate networks.
- Revoking a pairing immediately prevents further requests from that peer.
- The target Cetas retains ownership of every execution and approval.
- Malphite outage does not break local Session sharing or local peer collaboration.

## Current PR scope

PR #164 merged M4.3 snapshot/replay continuity; PR #166 merged the native owner lease and PR #171 merged initial local IPC framing and Unix endpoint. Full M4.4 host adapters, M7 peer collaboration, and the Malphite remote relay remain future work. PR #151 is an older unmerged implementation of event fanout whose behavior is already present in main; only its missing regression coverage is being ported separately.
