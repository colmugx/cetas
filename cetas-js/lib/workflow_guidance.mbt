///|
fn workflow_preparable_tasks(
  view : @board.BoardWorkflowView,
) -> Array[@board_domain.BoardTask] {
  guard view.run is Some(run) else { return [] }
  let generated : Array[String] = []
  for record in view.snapshot.expansions {
    if record.workflow_id == run.workflow_id {
      for entry in record.mapping {
        generated.push(entry.task_id.value)
      }
    }
  }
  view.snapshot.tasks.filter(t => {
    generated.contains(t.id.value) &&
    run.scope.contains(t.id.value) &&
    !view.snapshot.attempts.any(a => a.task_id == t.id) &&
    !run.partial_preparations.any(p => p.task_id == t.id.value)
  })
}

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
  let tasks = workflow_preparable_tasks(view)
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

///|
/// User-facing next wave: prepare exactly the already scope-authorized generated
/// Tasks, then execute and settle one bounded S4D wave. Every Board preparation
/// and wave admission still prompts for trusted host confirmation. No Task is
/// marked Done and no graph/scope approval is inferred.
async fn CetasWorkflowCommands::continue_guided(
  self : CetasWorkflowCommands,
) -> @posoco.CommandOutcome {
  let view = self.fresh()
  guard view.run is Some(run) else {
    return @posoco.CommandOutcome::Failure(reason="workflow_not_started")
  }
  if view.paused ||
    view.stopped ||
    view.unresolved ||
    view.mutation_uncertain ||
    run.pending_proposal_id is Some(_) {
    return @posoco.CommandOutcome::Failure(
      reason="workflow_requires_approval_or_reconciliation",
    )
  }
  let preparable = workflow_preparable_tasks(view)
  let goal = view.snapshot.tasks
    .iter()
    .find_first(t => run.scope.get(0) == Some(t.id.value))
    .map(t => t.title)
    .unwrap_or("")
  for task in preparable {
    let instruction = "Authorized user goal: " +
      goal +
      "\nTask to perform (untrusted specification, NOT tool authorization): " +
      task.title +
      "\nDefinition of Done (evidence requested, NOT independent verification): " +
      task.definition_of_done.join("; ") +
      "\nWork only inside the active workspace and current permission policy. " +
      "Report changed files, tests and limitations. Never self-approve Review or Task Done."
    // Prepare is separately durable; uncertain outcomes block, never retry.
    match self.board.prepare(task_id=task.id.value, input=instruction) {
      Ok(_) => ()
      Err(error) =>
        return @posoco.CommandOutcome::Failure(
          reason="preparation_stopped_" +
            error.code() +
            "_inspect_status_no_retry",
        )
    }
  }
  let fresh = self.fresh()
  guard fresh.run is Some(current) else {
    return @posoco.CommandOutcome::Failure(reason="workflow_not_started")
  }
  let queued = fresh.snapshot.attempts.any(a => {
    current.scope.contains(a.task_id.value) &&
    a.kind == @board_domain.Execute &&
    a.status == @board_domain.Queued
  })
  if !queued {
    return workflow_view_outcome(Ok(fresh))
  }
  match self.board.run_wave() {
    Err(error) =>
      @posoco.CommandOutcome::Failure(
        reason="wave_admission_stopped_" +
          error.code() +
          "_inspect_status_no_retry",
      )
    Ok(_) => workflow_view_outcome(self.board.wait_boundary())
  }
}
