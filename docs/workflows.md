# Controlled Board workflows — cetas-js

[Configuration](configuration.md) · [Architecture](architecture.md)

Board workflows are an **opt-in cetas-js feature**. They use Posoco Board's
existing dynamic controller, parallel runner and owned Posoco Agents. They are
not another Cetas scheduler, a `/plan` mode, or an automatic recursive agent.
`cetas-run` intentionally does not compose Board. ACP, the native terminal and
web hosts do not expose this feature.

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

## Commands and the two approvals

Use `/workflow` for the extension's interactive action picker, or the explicit
command IDs below. These are trusted user commands, **not model-callable tools**.
Inputs and approvals use Cetas's existing extension UI.

| Command | Operation |
| --- | --- |
| `/board.workflow.start` | Approve bounded workflow start and create its initial parent Task |
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

## Permissions and capability boundaries

- `readonly`: workflow mutations/admissions are refused; inspection, withdrawal
  and cancellation remain available.
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

1. Start a workflow and name its parent Task. Inspect and accept the budget
   confirmation. The workflow starts at a quiescent boundary.
2. Request a proposal for that parent with the coding requirement. Confirm one
   planning run. This is a real S4A-owned Posoco Agent turn, recorded by identity
   and charged to the same execution/time budget as task execution.
3. Inspect the preview. It may propose A “Implement validation” and B “Add
   regression tests”, with B depending on A. Invalid output is rejected before
   graph approval and creates no generated Tasks.
4. Approve the **graph**. Board persists one atomic `ExpandGraph` transaction,
   publishes one authoritative event and advances revision once. Inspect the
   canonical IDs. Both Tasks are `Created`, with no Attempts.
5. Separately approve that committed expansion's **execution scope**. Neither
   Task is executable merely because this succeeds.
6. Prepare A and B separately, supplying the actual trusted execution instruction
   for each. Board uses legal `Created → Refining → Ready` commands and queues
   host-generated Execute Attempts. Preparation is independently durable per
   command, not part of the atomic graph transaction.
7. Run the next wave and wait. A can execute; B remains blocked because A is not
   Board-stage `Done`. The Attempt result is durable; a successful Agent return
   leaves A's Task stage unchanged.
8. Independently check A's changes and test evidence. Use legal Task transitions
   `Ready → Running → Review → Done` one at a time through the operator command.
   This is not automatic Review-Attempt approval.
9. Run the next wave. Fresh S4B planning now sees A `Done`, so B may execute if
   its input, scope, remaining budgets and other eligibility checks still hold.
   Verify its evidence and advance its Task explicitly if appropriate.

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
outputs are not written to the Board identity journal.

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
crash resume. A stale lock or unresolved binding requires operator reconciliation;
Cetas never steals the lock or replays an Agent call. Preserve the directory
before investigating. Do not remove the lock without proving the old process is
terminated and reconciling unresolved external effects.

Disabling the feature leaves storage intact. Rollback must retain Board schema
v2 and journal v1 support; do not downgrade or delete expansion identities.
Deterministic integration tests use actual Posoco Agents and controlled
ModelPorts with real file persistence. They do not claim real-provider network
or arbitrary tool-side-effect coverage.
