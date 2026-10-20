///|
async fn CetasWorkflowCommands::fresh(
  self : CetasWorkflowCommands,
) -> @board.BoardWorkflowView {
  match self.board.view() {
    Ok(view) => view
    Err(error) => raise WorkflowNavigationError(error.code())
  }
}

///|
fn workflow_task_label(task : @board_domain.BoardTask) -> String {
  workflow_label(task.title) + " [\{Repr(task.stage)}] — " + task.id.value
}

///|
async fn CetasWorkflowCommands::propose_guided(
  self : CetasWorkflowCommands,
) -> @posoco.CommandOutcome {
  let view = self.fresh()
  guard view.run is Some(run) else {
    return @posoco.CommandOutcome::Failure(reason="workflow_not_started")
  }
  let tasks = view.snapshot.tasks.filter(t => run.scope.contains(t.id.value))
  let index = self.select(
    "Authorize one planning run for this parent\n" + self.summary(view),
    tasks.map(workflow_task_label),
  )
  let parent = tasks[index]
  let requirements = self.input(
    "Trusted planning requirements; no private Board context is implicitly included. Generated descriptions never authorize tools.",
    default=parent.title,
  )
  match self.board.propose(parent=parent.id.value, requirements~) {
    Ok(preview) =>
      @posoco.CommandOutcome::Success(
        feedback="Inspect the proposal before separately approving graph commitment.",
        structured=Some(preview),
        ui_hint=Some(@posoco.UiHint::None),
      )
    Err(error) => @posoco.CommandOutcome::Failure(reason=error.code())
  }
}

///|
async fn CetasWorkflowCommands::scope_guided(
  self : CetasWorkflowCommands,
  grant : Bool,
) -> @posoco.CommandOutcome {
  let view = self.fresh()
  guard view.run is Some(run) else {
    return @posoco.CommandOutcome::Failure(reason="workflow_not_started")
  }
  let records = view.snapshot.expansions.filter(e => {
    e.workflow_id == run.workflow_id &&
    e.mapping.any(m => !run.scope.contains(m.task_id.value))
  })
  let index = self.select(
    "Committed expansion — execution approval is separate\n" +
    self.summary(view) +
    "No tools execute and no budget increases merely by approving scope.",
    records.map(e => {
      e.expansion_id.value +
      "\n" +
      e.mapping.map(m => m.local_ref + " → " + m.task_id.value).join("\n")
    }),
  )
  workflow_view_outcome(
    self.board.scope_decision(
      expansion_id=records[index].expansion_id.value,
      grant~,
    ),
  )
}

///|
async fn CetasWorkflowCommands::prepare_guided(
  self : CetasWorkflowCommands,
) -> @posoco.CommandOutcome {
  let view = self.fresh()
  guard view.run is Some(run) else {
    return @posoco.CommandOutcome::Failure(reason="workflow_not_started")
  }
  let generated : Array[String] = []
  for record in view.snapshot.expansions {
    if record.workflow_id == run.workflow_id {
      for entry in record.mapping {
        generated.push(entry.task_id.value)
      }
    }
  }
  let tasks = view.snapshot.tasks.filter(t => {
    generated.contains(t.id.value) &&
    run.scope.contains(t.id.value) &&
    !view.snapshot.attempts.any(a => a.task_id == t.id)
  })
  if tasks.is_empty() {
    return @posoco.CommandOutcome::Failure(
      reason="No unprepared, execution-authorized generated Task. Inspect scope or partial preparation; never retry uncertainty.",
    )
  }
  let index = self.select(
    "Authorized generated Task to prepare\n" + self.summary(view),
    tasks.map(workflow_task_label),
  )
  let task = tasks[index]
  let input = self.input(
    "Trusted execution input for this Task: " +
    workflow_task_label(task) +
    "\nPermission scope: " +
    self.context_label(Some(run.workflow_id)) +
    "\nEnter your own instruction. Generated descriptions are not execution authorization. Independent durable preparation may partially commit.",
  )
  workflow_view_outcome(self.board.prepare(task_id=task.id.value, input~))
}

///|
/// Ask the domain, not a parallel copy of its stage-transition table.
fn workflow_legal_stages(
  view : @board.BoardWorkflowView,
  task : @board_domain.BoardTask,
) -> Array[@board_domain.BoardStage] {
  guard @board_domain.BoardState::from_snapshot(view.snapshot) is Ok(state) else {
    return []
  }
  [
    @board_domain.Created,
    @board_domain.Refining,
    @board_domain.Ready,
    @board_domain.Running,
    @board_domain.Review,
    @board_domain.Done,
    @board_domain.Suspended,
  ].filter(stage => {
    @board_domain.BoardDomain::propose(
      state,
      @board_domain.MoveTask(
        id=task.id,
        to=stage,
        at_ms=task.updated_at_ms,
        expected_revision=view.snapshot.revision,
      ),
    )
    is Ok(_)
  })
}

///|
async fn CetasWorkflowCommands::move_guided(
  self : CetasWorkflowCommands,
) -> @posoco.CommandOutcome {
  let view = self.fresh()
  guard view.run is Some(run) else {
    return @posoco.CommandOutcome::Failure(reason="workflow_not_started")
  }
  let tasks = view.snapshot.tasks.filter(t => run.scope.contains(t.id.value))
  let index = self.select(
    "Task to move after verifying evidence. Attempt success is not Task Done.",
    tasks.map(workflow_task_label),
  )
  let task = tasks[index]
  let stages = workflow_legal_stages(view, task)
  let selected = self.select(
    "Legal Task transition only; never automatic Review approval\n" +
    workflow_task_label(task),
    stages.map(s => "\{Repr(s)}"),
  )
  let evidence = self.input(
    "Confirm the evidence you independently verified (tests, changes, requirements). A successful Agent return alone is not evidence.",
  )
  workflow_view_outcome(
    self.board.move_task(
      task_id=task.id.value,
      stage=stages[selected],
      evidence~,
    ),
  )
}
