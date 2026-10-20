# Controlled Board workflows — cetas-js

[Configuration](configuration.md) · [Architecture](architecture.md)

Board workflows are an **opt-in cetas-js feature**. They use Posoco Board's
existing dynamic controller, parallel runner and owned Posoco Agents. They are
not another Cetas scheduler, a `/plan` mode, or an automatic recursive agent.
`cetas-run` intentionally does not compose Board. ACP, the native terminal and
web hosts do not expose this feature.

Since S5A the cetas-js host composes a **product parent extension** on top of
Board's workflow CommandPort. It is navigation and presentation only: Board
retains every approval, mutation, durability and lifecycle barrier, and the
parent is a facade over that same runtime — same extension id, same command
IDs, one Board runtime per workspace, never a second one. It requires the
host's trusted UI capability; navigation without a trusted UI fails as
navigation, never as a silent mutation.

## Enable and configure

Configure a provider and select a model through the existing `/login` and
`/model` commands first. Add this optional block to `~/.cetas/settings.json`,
retaining your existing provider settings, then restart cetas-js:

```json
{
  "workflow": {
    "enabled": true,
    "max_executions": 8,
    "max_elapsed_ms": 600000,
    "execution_timeout_ms": 60000,
    "max_concurrency": 2,
    "max_expansions": 2,
    "max_generated_tasks": 20,
    "max_depth": 16,
    "continue_on_confirmed_failure": false
  }
}
```

An absent section means disabled: no Board runtime, lock or commands are
composed. Unknown fields and invalid budgets are configuration errors, even
when disabled. Execution count is 1–1000, concurrency 1–8, elapsed duration
1–86400000 ms, execution timeout positive and no greater than elapsed duration,
expansions 1–16, generated tasks 1–200, and graph depth 2–16. The initial values
above are the defaults, not a promise that a provider can finish within them.

The planning Agent and generated-task Agents use the existing model-manager
factory (both Providers and Magpie). Selection and effort are pinned for each
workflow at its first Agent composition; changing the parent's `/model` does
not silently switch an established workflow's child model. Each run gets a
fresh router/model-manager wrapper, Agent, session identity, permission policy
and tool composition. No child borrows the parent's mutable session, observers,
MCP/Pi runtime or delegation tools.

The product UI reports this context back to you: model, effort, whether the
workflow's selection is already pinned (`model_pinned`), permission mode,
workspace, concurrency and execution timeout. Until the first planning
composition pins the selection, the menu shows the parent's current active
model; afterwards it shows the pinned one.

## The state-aware /workflow menu

`/workflow` (command id `board.workflow`) opens the product overview instead of
Board's plain picker. Opening it is a read-only act: it fetches one fresh
authoritative view and renders a readable summary — goal, phase, active
Agents, remaining execution/expansion/time budgets, blocked Tasks, Board
revision and Task stage counts — plus the model/permission context. The menu
header itself says "opening this menu changes nothing", and it means it:
opening or cancelling submits no mutation, creates no additional runtime,
writes no lock or journal file, and calls no tools. Cancelling returns another fresh
read-only view.

The next-step choices are derived from that view, not a fixed list:

- Unresolved ownership or an uncertain mutation offers reconciliation first
  and withholds new mutations/admissions; inspection and withdrawal remain available.
- No in-process authorization offers "Start from a coding goal"; stored graphs
  never restore authority.
- A pending proposal offers preview, graph approve and graph reject.
- A committed expansion with Tasks outside the authorized scope offers scope
  approve/reject.
- Active Agents or an in-flight operation offer wait; a quiescent, non-stopped
  workflow offers prepare, run and move, plus propose while no proposal is
  pending and expansion/execution budgets remain. A paused workflow offers
  resume instead of dispatch.
- Status is always offered; pause, stop and cancel appear while a workflow is
  active and not stopped.

Under the `readonly` permission mode the menu is filtered to inspection and
withdrawal actions (status, preview, pause, stop, cancel, reconcile), and any
other action — including guided start — is refused before any input or
approval prompt is shown.

Task titles shown in the menu and prompts pass through a display sanitizer
that replaces terminal control characters (including ANSI escape sequences)
with spaces. This is presentation only: Board task IDs and stored titles are
untouched, and every explicit `/board.workflow.*` ID below keeps working
exactly as before. Hosts that do not compose the parent still see Board's own
picker for the same IDs.

## Commands and the two approvals

Use `/workflow` for the extension's guided picker, or the explicit command IDs
below — the picker drives the same operations through the same IDs. These are
trusted user commands, **not model-callable tools**. They take no JSON
arguments; every decision is made through Cetas's existing extension UI (the
terminal renders the guided selects and inputs as its standard panels).

| Command | Operation |
| --- | --- |
| `/board.workflow.start` | Approve bounded workflow start and create its initial parent Task from the coding goal |
| `/board.workflow.status` | Fresh Board graph, attempts, scope, budgets, blocked reasons and actual execution identities |
| `/board.workflow.propose` | Select an authorized parent, supply requirements and approve one planning run |
| `/board.workflow.preview` | Inspect the strictly decoded/validated DAG preview |
| `/board.workflow.graph.approve` | Confirm the exact proposal/digest/revision for atomic graph commit |
| `/board.workflow.graph.reject` | Discard the pending proposal without graph mutation |
| `/board.workflow.scope.approve` | Separately authorize the exact canonical mapping from a committed expansion |
| `/board.workflow.scope.reject` | Keep the committed graph but deny execution-scope extension |
| `/board.workflow.prepare` | Supply trusted execution input and approve legal Task preparation plus one queued Execute Attempt |
| `/board.workflow.run` | Approve dispatch of the next eligible bounded wave |
| `/board.workflow.wait` | Await the safe settlement boundary and inspect status |
| `/board.workflow.move` | Operator-controlled legal Task transition after checking evidence |
| `/board.workflow.pause` | Withdraw new admission and pending approval work |
| `/board.workflow.resume` | Explicit in-process resume; does not itself dispatch a wave |
| `/board.workflow.stop` | Stop admitting future waves; let admitted work settle |
| `/board.workflow.cancel` | Cancel owned work by its exact execution identity and join settlement |
| `/board.workflow.reconcile` | Read authoritative evidence for an uncertain expansion/preparation; never replay it |

**Graph approval** authorizes only one durable additive graph transaction. Its
preview shows parent, titles, descriptions, dependencies, Definition of Done,
proposal digest, revision and resource consequences. Generated descriptions are
untrusted data, never shell commands or tool authority.

**Execution-scope approval** happens only after commit. It binds the same
workflow, parent lineage, canonical Task mapping and fresh revision. It does not
add budget, queue Attempts or change Task stages. Refusing scope approval does
not roll back the graph. Preparation and wave dispatch are separate explicit
operations after scope approval.

Status, preview, pause, stop and cancel are the only non-prompting Board commands
allowed through the host's control lane while another command is occupied. The
ordinary command lock still protects graph approval, scope approval,
preparation and execution admission.

## What the presenter adds (and does not)

The product parent adds readable status and proposal prompts; it never adds
authority or automatic Task progression:

- Guided prompts carry the decision context to each step: planning
  requirements default to the parent Task title; preparation asks for each
  Task's own trusted input and shows the permission scope; transitions ask for
  the evidence you verified.
- Every successful outcome is annotated with a `cetas_workflow` context object
  (model, effort, pin state, permission, workspace, concurrency, timeout,
  initial scope, planning/execution tool scope) and the feedback "Workflow
  observation; no automatic Task completion." Status-like outcomes enrich the
  same detached authoritative view with per-Task execution authorization,
  Attempts and run counters — they never re-read after a mutation just to
  manufacture a success message, and the UI hint is always "none", so no
  prompt takes over the session.
- During owned work, a read-only status observer shows changes to execution
  identities and settlement through the existing status control lane. It stops
  on quiescence, uncertainty or display shutdown; closing the observer never
  cancels Agents. A status-read failure is surfaced once without retrying any
  mutation or execution. Failed preparation also triggers one status inspection
  to expose independently committed steps, never a replay.
- The proposal is strictly decoded JSON plus a text menu — **not a graphical
  DAG editor**, and Cetas claims no provider-side network behaviour and no
  crash resume. Restart evidence stays read-only, as described below.

## Permissions and capability boundaries

- `readonly`: workflow mutations/admissions are refused; inspection, withdrawal
  and cancellation remain available, and the guided menu is filtered
  accordingly.
- `workspace_write` / `interactive`: child tools use the current Cetas permission
  policy and its existing confirmation source, anchored to the workspace.
- `yolo`: affects child tool permission only. It **does not bypass** workflow
  start, planning, graph, scope, preparation or wave confirmations.

Planning Agents have **no tools**. Execution Agents get freshly reconstructed
workspace read/search/write/edit/shell tools behind their own permission policy,
not the parent's unrestricted extension catalog. They cannot call workflow
commands, create more child Agents, or approve their own plan. Maximum tool
rounds per execution is bounded at 16. A permission change is checked again
before subsequent workflow admission; it does not rewrite an admitted execution's
identity or imply retroactive rollback of tool effects.

## Walkthrough: a coding request to verified execution

Suppose the request is “Add validation for a configuration field and cover it
with tests.”

1. Open `/workflow` and choose "Start from a coding goal". The single start
   input collects only the goal text — stored as the parent Task's metadata,
   never credentials. The same prompt displays what you are authorizing: the
   configured budget (executions including planning, concurrency, deadline),
   the initial scope — one new root Task; existing Board tasks are not
   implicitly authorized — and the current model/effort/permission context.
   There are no budget overrides in this input; changing budgets means editing
   settings and restarting. Model selection pins at the workflow's first
   planning composition, and separate confirmations are still required.
2. Choose "Generate a Task DAG with one planning Agent", pick the parent and
   confirm one planning run. This is a real S4A-owned Posoco Agent turn,
   recorded by identity and charged to the same execution/time budget as task
   execution.
3. Inspect the preview. It may propose A “Implement validation” and B “Add
   regression tests”, with B depending on A. Invalid output is rejected before
   graph approval and creates no generated Tasks.
4. Approve the **graph**. Board persists one atomic `ExpandGraph` transaction,
   publishes one authoritative event and advances revision once. Inspect the
   canonical IDs. Both Tasks are `Created`, with no Attempts.
5. Separately approve that committed expansion's **execution scope**. The menu
   states plainly that no tools execute and no budget increases by approving
   scope; neither Task is executable merely because this succeeds.
6. Prepare A and B separately, supplying the actual trusted execution
   instruction for each — the generated description is never the authorization.
   Board uses legal `Created → Refining → Ready` commands and queues
   host-generated Execute Attempts. Preparation is independently durable per
   command, not part of the atomic graph transaction, and partial preparation
   is reported with its exact step.
7. Run the next wave explicitly and wait. A can execute; B remains blocked
   because A is not Board-stage `Done`. The Attempt result is durable; a
   successful Agent return leaves A's Task stage unchanged.
8. Independently check A's changes and test evidence, then use "Verify evidence
   and advance a Task legally". The menu offers only the transitions the Board
   domain itself accepts for that Task — it asks the domain's stage machine,
   not a copy of it — and records your evidence note. Legal Task transitions
   `Ready → Running → Review → Done` are taken one at a time; this is not
   automatic Review-Attempt approval.
9. Run the second wave. Fresh S4B planning now sees A `Done`, so B may execute
   if its input, scope, remaining budgets and other eligibility checks still
   hold. Verify its evidence and advance its Task explicitly if appropriate.

There is no success inference from terminal prose. The status command reads
Board state and the execution owner's actual bindings. “Attempt Succeeded” and
“Task Done” are different facts; a fully settled workflow can still be blocked.

## Budgets, pause and failures

The elapsed deadline includes planning, approvals, preparation, pauses and
execution. Scope extension cannot replenish it or the shared execution count.
Only one proposal/approval operation is active at a time. Further expansion,
including expansion under a generated parent, requires a new explicit user
operation and authorization within the original remaining limits.

Pause withdraws pending planning/approval and prevents new admission; already
admitted task Agents settle through the existing runner. Pausing a planning
Agent cancels that turn. With the default stop-on-confirmed-failure policy its
cancelled outcome can terminate the workflow; it is not silently resumed. The
explicit `continue_on_confirmed_failure` policy permits continuation after
confirmed failure/cancellation, but never after unresolved ownership. Resume
always re-reads authoritative state and never restores a discarded approval.
Stop is final for this in-process authorization. Cancel is not graph rollback.

Missing/unavailable models, unsupported protocols, invalid proposals and denied
permissions fail without granting new graph or execution authority. Revision
conflict requires refresh and renewed approval, not an automatic rebase/retry.
A partially prepared Task is reported with its exact preparation step and
Attempt identity. Uncertain writes/executions freeze admission; reconcile only
reads evidence. No new IDs are generated to retry ambiguous work.

## Storage, ownership and restart limits

Each workspace has its own Cetas-owned namespace:

```text
~/.cetas/board/<project session bucket>/
  board.json         # Board snapshot schema v2
  events.jsonl       # authoritative audit events, never replayed as mutations
  executions.json    # execution identity journal v1, not prompts/results
  execution.lock     # exclusive owner, never auto-removed as stale
```

The bucket uses the same normalized workspace identity as Cetas session buckets,
but Board state and Cetas transcripts are separate objects. User Task metadata
is persisted; raw planning requirements, execution inputs, credentials and model
outputs are not written to the Board identity journal. Merely opening or
cancelling the `/workflow` menu writes none of these files.

The extension owns Node-compatible file operations (`node:fs`, `node:path`,
`node:crypto`), fsync/rename, lock acquisition, single-writer coordinator and
shutdown. There are no Bun-specific persistence APIs or JS in-memory fallback.
Filesystems/platforms lacking required directory-fsync or atomic rename fail
closed rather than claim weaker durability. Test evidence on one platform is
not a durability certification of other platforms or network filesystems.

At shutdown Board stops admission, cancels/joins actual Agents, waits for runner
and owner settlement, and only releases the journal lock after confirmed
termination. Failed join retains ownership and is surfaced as failure. The
backend is closed through the extension lifecycle, not by host UI cleanup.

Restart can inspect durable graph/identity evidence read-only. It **does not**
restore workflow approval, scope authorization, execution input or automatic
crash resume — the product menu reflects this too: with no in-process
authorization it offers start, never a resurrection of a previous run. A stale
lock or unresolved binding requires operator reconciliation; Cetas never steals
the lock or replays an Agent call. Preserve the directory before investigating.
Do not remove the lock without proving the old process is terminated and
reconciling unresolved external effects.

Disabling the feature leaves storage intact. Rollback must retain Board schema
v2 and journal v1 support; do not downgrade or delete expansion identities.
Deterministic integration tests use actual Posoco Agents and controlled
ModelPorts with real file persistence. They do not claim real-provider network
or arbitrary tool-side-effect coverage.
