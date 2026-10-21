# Goal mode in Cetas JS

Goal mode runs a sequence of ordinary Posoco Agent turns against a persistent
objective. It does **not** grant new permissions, require a JEV login, or
replace PlanMode.

## Commands

| Command | Behavior |
|---|---|
| `/goal <objective>` | Start a fresh bounded goal in the current session |
| `/goal status` | Inspect the active runner status without interrupting work |
| `/goal pause` | Request a pause at a safe turn boundary |
| `/goal resume` | Resume a paused goal; if the process restarted, restore its checkpoint |

The default goal budget is 20 turns. When the assistant claims success,
Cetas asks the user to confirm that the goal was **independently verified**.
Approval is recorded as human-review evidence; rejection returns the agent
to work within its remaining budget; cancellation leaves the goal paused and
inconclusive. The LLM cannot declare itself verified.

The `goal_update_plan` tool is active only inside a Goal turn. Existing
`/plan` continues to control *permission-gated planning* and remains
separate from Goal's internal progress plan.

## Recovery and state

Pausing writes a versioned Goal checkpoint under the Cetas session directory
in `goals/<sha256(session-id)>.json`. The file is written via a temporary
file and atomic rename. It is bound to the exact JSONL transcript content
digest captured at the same settled boundary.

On restart, `/goal resume` restores only if the saved session ID and
transcript digest still match. If the transcript changed, the host **refuses
to resume** instead of risking repeated tool effects. The user must inspect
the session and start a new Goal. The system is not an exactly-once execution
engine: a crash while an external command is in progress still requires
manual reconciliation.

The host only writes a checkpoint when Goal stops nonterminally. Completing
or otherwise finishing a Goal removes the earlier checkpoint. Goal state is
scoped to the composed Agent instance (one active or paused Goal at a time);
switching to a different session does not silently migrate it.

## JEV and verification

No `DecisionPort` is part of the Cetas JS default composition. All goal
control and human approval work without logging into JEV. Future provider
wiring may supply optional semantic advice, but it can never supersede the
runtime's budget or independent evidence requirements.

The first implementation uses **explicit human completion approval** as
its production verifier. It does not automatically execute a test suite or
assert that the workspace is correct. Automation requires a separately
audited `GoalVerifier` that obtains real evidence from tools/workspace state.
