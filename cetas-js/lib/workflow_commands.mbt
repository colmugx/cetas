///|
/// Product navigation only. Board retains every approval, mutation and lifecycle
/// barrier; this facade replaces its command presentation, not its runtime.
priv struct CetasWorkflowCommands {
  board : @board.BoardWorkflows
  agents : CetasWorkflowAgents
  settings : @cetas_core.CetasWorkflowSettings
  mut ui : &@posoco.UiPort?
}

///|
impl @posoco.Extension for CetasWorkflowCommands with fn extension_id(self) {
  self.board.extension_id()
}

///|
impl @posoco.Extension for CetasWorkflowCommands with fn manifest(self) {
  @posoco.ExtensionManifest(
    id=self.board.extension_id(),
    commands=[self],
    lifecycle=[self.board, self],
    requires=[@posoco.Capability::Ui],
  )
}

///|
impl @posoco.Lifecycle for CetasWorkflowCommands with fn on_compose(self, view) {
  self.ui = view.ui()
}

///|
impl @posoco.Lifecycle for CetasWorkflowCommands with fn on_shutdown(_) {
  ()
}

///|
impl @posoco.CommandPort for CetasWorkflowCommands with fn commands(self) {
  let definitions = self.board.commands().map(def => {
    if def.id == "board.workflow" {
      {
        ..def,
        label: "Workflow — goal, approvals and progress",
        description: "Open the workflow overview and guided next steps",
      }
    } else {
      def
    }
  })
  // Posoco routes by canonical command id, not by CommandDef aliases.
  // The literal /workflow command therefore needs its own registered id.
  let entry = definitions.iter().find_first(def => def.id == "board.workflow").unwrap()
  definitions.push({
    ..entry,
    id: "workflow",
    aliases: [],
  })
  definitions
}

///|
priv suberror WorkflowNavigationCancelled {
  WorkflowNavigationCancelled
}

///|
priv suberror WorkflowNavigationError {
  WorkflowNavigationError(String)
}

///|
async fn CetasWorkflowCommands::select(
  self : CetasWorkflowCommands,
  prompt : String,
  options : Array[String],
) -> Int32 {
  if options.is_empty() {
    raise WorkflowNavigationError(
      "No matching workflow action or Task. Inspect fresh status; no mutation was submitted.",
    )
  }
  guard self.ui is Some(ui) else {
    raise WorkflowNavigationError("trusted_ui_required")
  }
  match ui.request(@posoco.UiRequest::Select(prompt~, options~, default=None)) {
    @posoco.UiResponse::Selected(index) if index >= 0 &&
      index < options.length() => index
    _ => raise WorkflowNavigationCancelled
  }
}

///|
async fn CetasWorkflowCommands::input(
  self : CetasWorkflowCommands,
  prompt : String,
  default? : String,
) -> String {
  guard self.ui is Some(ui) else { raise WorkflowNavigationCancelled }
  match ui.request(@posoco.UiRequest::Input(prompt~, default~)) {
    @posoco.UiResponse::Text(text) if !text.trim().is_empty() => text
    _ => raise WorkflowNavigationCancelled
  }
}

///|
fn CetasWorkflowCommands::context(
  self : CetasWorkflowCommands,
  workflow : String?,
) -> Json {
  let selection = match workflow {
    Some(id) => self.agents.selections.get(id)
    None => None
  }
  let (model, effort) = selection.unwrap_or(
    (
      self.agents.manager.manager_active_model_id(),
      self.agents.manager.manager_active_effort(),
    ),
  )
  {
    "model": model,
    "effort": effort.unwrap_or("provider default"),
    "model_pinned": Json::boolean(selection is Some(_)),
    "permission": "\{Repr((self.agents.parent_mode)())}",
    "workspace": self.agents.ctx.cwd,
    "max_concurrency": self.settings.max_concurrency,
    "execution_timeout_ms": self.settings.execution_timeout_ms,
    "initial_scope": "One new root Task; existing Board tasks are not implicitly authorized",
    "planning_tools": "none",
    "execution_tools": "permission-scoped read/search/write/edit/shell; no delegation or Board mutation",
  }
}

///|
fn CetasWorkflowCommands::context_label(
  self : CetasWorkflowCommands,
  workflow : String?,
) -> String {
  let context = self.context(workflow)
  guard context
    is {
      "model": String(model),
      "effort": String(effort),
      "permission": String(permission),
      "model_pinned": pinned,
      ..
    } else {
    return "Model / permission context unavailable; inspect status before approval."
  }
  "Model: " +
  workflow_label(model) +
  " | effort: " +
  workflow_label(effort) +
  (if pinned is True {
    " (pinned)"
  } else {
    " (pins at first planning composition)"
  }) +
  "\nPermission: " +
  workflow_label(permission) +
  " | concurrency: \{self.settings.max_concurrency}" +
  " | per-Agent timeout: \{self.settings.execution_timeout_ms} ms" +
  "\nWorkspace: " +
  workflow_label(self.agents.ctx.cwd) +
  "\nPlanning: no tools. Execution: permission-scoped workspace tools; no delegation or Board mutation."
}

///|
fn CetasWorkflowCommands::summary(
  self : CetasWorkflowCommands,
  view : @board.BoardWorkflowView,
) -> String {
  let sb = StringBuilder()
  sb.write_string("Workflow (opt-in) — opening this menu changes nothing.\n")
  match view.run {
    None =>
      sb.write_string(
        "No in-process workflow authorization. Stored graphs do not restore authority.\n",
      )
    Some(run) => {
      let goal = view.snapshot.tasks
        .iter()
        .find_first(t => run.scope.get(0) == Some(t.id.value))
      sb.write_string(
        "Goal: " +
        goal
        .map(t => workflow_label(t.title))
        .unwrap_or(workflow_label(run.workflow_id)) +
        "\n",
      )
      sb.write_string(
        "Phase: \{Repr(run.phase)} | Running Agents: \{view.executions.filter(e => e.phase is Running).length()} | Owned active slots: \{run.runner.active_count}\n",
      )
      sb.write_string(
        "Remaining: \{run.runner.remaining_executions} executions, \{run.remaining_expansions} expansions, \{run.runner.remaining_ms} ms\n",
      )
      sb.write_string(
        "Blocked Tasks: \{run.blocked.length()} | Board revision: \{view.snapshot.revision}\n",
      )
    }
  }
  sb.write_string(
    "Board Task stages: " +
    [
      @board_domain.Created,
      @board_domain.Refining,
      @board_domain.Ready,
      @board_domain.Running,
      @board_domain.Review,
      @board_domain.Done,
      @board_domain.Suspended,
    ]
    .map(stage => {
      "\{Repr(stage)}=\{view.snapshot.tasks.filter(t => t.stage == stage).length()}"
    })
    .join(" ") +
    "\n",
  )
  if view.unresolved || view.mutation_uncertain {
    sb.write_string(
      "WARNING: unresolved ownership or uncertain mutation. Inspect/reconcile only; never retry.\n",
    )
  }
  sb.write_string(
    "Task Done, Attempt Succeeded and Review approval are separate facts.\n",
  )
  sb.write_string(self.context_label(view.run.map(r => r.workflow_id)) + "\n")
  sb.to_string()
}

///|
fn workflow_label(value : String) -> String {
  String::from_array(
    value
    .iter()
    .map(c => {
      if c.to_int() < 32 || (c.to_int() >= 127 && c.to_int() <= 159) {
        ' '
      } else {
        c
      }
    })
    .to_array(),
  )
}

///|
fn workflow_terminal(phase : @board_workflow.WorkflowPhase) -> Bool {
  phase is (Stopped | Completed | Failed | Unresolved)
}

///|
fn workflow_actions(view : @board.BoardWorkflowView) -> Array[(String, String)] {
  let choices : Array[(String, String)] = []
  if view.unresolved || view.mutation_uncertain {
    choices.push(
      ("reconcile", "Inspect uncertainty — read-only reconciliation"),
    )
  } else {
    match view.run {
      None =>
        if !view.stopped {
          choices.push(("start", "Start from a coding goal"))
        }
      Some(run) => {
        let terminal = workflow_terminal(run.phase)
        if run.pending_proposal_id is Some(_) {
          choices.push(("preview", "Inspect proposed DAG (no commit)"))
          if !terminal && !view.stopped {
            choices.push(
              ("graph.approve", "Approve graph only — create durable Tasks"),
            )
            choices.push(("graph.reject", "Reject pending graph"))
          }
        }
        if !terminal &&
          !view.stopped &&
          view.snapshot.expansions.any(e => {
            e.workflow_id == run.workflow_id &&
            e.mapping.any(m => !run.scope.contains(m.task_id.value))
          }) {
          choices.push(
            ("scope.approve", "Separately authorize committed execution scope"),
          )
          choices.push(
            ("scope.reject", "Deny execution scope — keep committed graph"),
          )
        }
        if run.runner.active_count > 0 || view.operation_active {
          choices.push(("wait", "Wait for current wave to settle"))
        } else if !view.stopped && !terminal {
          if view.paused {
            choices.push(
              ("resume", "Resume in-process authorization (no dispatch)"),
            )
          } else if run.pending_proposal_id is None {
            if !workflow_preparable_tasks(view).is_empty() {
              choices.push(
                ("prepare", "Prepare generated Tasks with trusted instructions"),
              )
            }
            if view.snapshot.attempts.any(a => {
                run.scope.contains(a.task_id.value) &&
                a.kind == @board_domain.Execute &&
                a.status == @board_domain.Queued
              }) {
              choices.push(
                ("run", "Run next eligible wave — explicit confirmation"),
              )
            }
            choices.push(("move", "Verify evidence and advance a Task legally"))
            if run.pending_proposal_id is None &&
              run.remaining_expansions > 0 &&
              run.runner.remaining_executions > 0 {
              choices.push(
                ("propose", "Generate a Task DAG with one planning Agent"),
              )
            }
          }
        }
      }
    }
  }
  choices.push(("status", "Inspect authoritative overview and blocked reasons"))
  if view.run is Some(_) && !view.stopped {
    choices.push(("pause", "Pause new admission"))
    choices.push(("stop", "Stop after the current wave"))
    choices.push(("cancel", "Cancel actual owned Agents (not graph rollback)"))
  }
  choices
}

///|
fn CetasWorkflowCommands::present(
  self : CetasWorkflowCommands,
  outcome : @posoco.CommandOutcome,
) -> @posoco.CommandOutcome {
  match outcome {
    @posoco.CommandOutcome::Success(structured=Some(Json::Object(fields)), ..) => {
      let fields = fields.copy()
      let workflow = match fields.get("workflow") {
        Some({ "workflow_id": String(id), .. }) => Some(id)
        _ =>
          match fields.get("workflow_id") {
            Some(String(id)) => Some(id)
            _ => None
          }
      }
      fields["cetas_workflow"] = self.context(workflow)
      @posoco.CommandOutcome::Success(
        feedback="Workflow observation; no automatic Task completion.",
        structured=Some(Json::object(fields)),
        ui_hint=Some(@posoco.UiHint::None),
      )
    }
    _ => outcome
  }
}

///|
fn workflow_view_outcome(
  value : Result[@board.BoardWorkflowView, @board.BoardWorkflowError],
) -> @posoco.CommandOutcome {
  match value {
    Ok(view) =>
      @posoco.CommandOutcome::Success(
        feedback="",
        structured=Some(workflow_observation(view)),
        ui_hint=Some(@posoco.UiHint::None),
      )
    Err(error) => @posoco.CommandOutcome::Failure(reason=error.code())
  }
}

///|
impl @posoco.CommandPort for CetasWorkflowCommands with fn invoke(
  self,
  id,
  args,
) {
  // The user supplies the highest-level goal once. Starting and planning
  // remain separately confirmed by the existing Board trusted UI.
  if (id == "workflow" || id == "board.workflow") &&
    args is { "goal": String(goal), .. } {
    if goal.trim().is_empty() || goal.length() > 256 {
      return @posoco.CommandOutcome::Failure(reason="invalid_workflow_goal")
    }
    if (self.agents.parent_mode)() == @permission.ReadOnly {
      return @posoco.CommandOutcome::Failure(reason="approval_denied")
    }
    match self.board.start(title=goal) {
      Err(error) => return @posoco.CommandOutcome::Failure(reason=error.code())
      Ok(view) => {
        guard view.run is Some(run) && !run.scope.is_empty() else {
          return @posoco.CommandOutcome::Failure(reason="workflow_start_missing_scope")
        }
        match self.board.propose(parent=run.scope[0], requirements=goal) {
          Ok(preview) =>
            return @posoco.CommandOutcome::Success(
              feedback="Planning complete. Review the graph proposal, then approve graph and execution scope separately using /workflow.",
              structured=Some(preview),
              ui_hint=Some(@posoco.UiHint::None),
            )
          Err(error) =>
            return @posoco.CommandOutcome::Failure(
              reason="workflow_started_planning_failed_" + error.code() +
              "_inspect_status_no_retry",
            )
        }
      }
    }
  }
  if !(args is Object(fields) && fields.is_empty()) {
    return self.board.invoke(id, args)
  }
  try {
    let action = if id == "workflow" || id == "board.workflow" {
      let view = match self.board.view() {
        Ok(view) => view
        Err(error) =>
          return @posoco.CommandOutcome::Failure(reason=error.code())
      }
      let choices = workflow_actions(view).filter(c => {
        (self.agents.parent_mode)() != @permission.ReadOnly ||
        ["status", "preview", "pause", "stop", "cancel", "reconcile"].contains(
          c.0,
        )
      })
      let index = self.select(self.summary(view), choices.map(c => c.1))
      "board.workflow." + choices[index].0
    } else {
      id
    }
    if (self.agents.parent_mode)() == @permission.ReadOnly &&
      ![
        "board.workflow.status", "board.workflow.preview", "board.workflow.pause",
        "board.workflow.stop", "board.workflow.cancel", "board.workflow.reconcile",
      ].contains(action) {
      return @posoco.CommandOutcome::Failure(reason="approval_denied")
    }
    let result = match action {
      "board.workflow.start" => {
        let goal = self.input(
          "Coding goal / workflow title (stored Task metadata, no credentials)\nInitial scope: one new root Task.\nConfigured budget: \{self.settings.max_executions} executions including planning; concurrency \{self.settings.max_concurrency}; deadline \{self.settings.max_elapsed_ms} ms.\n" +
          self.context_label(None) +
          "\nModel selection pins at first planning composition. Separate confirmations are still required.",
        )
        workflow_view_outcome(self.board.start(title=goal))
      }
      "board.workflow.status" => workflow_view_outcome(self.board.view())
      "board.workflow.run" => workflow_view_outcome(self.board.run_wave())
      "board.workflow.wait" => workflow_view_outcome(self.board.wait_boundary())
      "board.workflow.resume" =>
        workflow_view_outcome(self.board.resume_workflow())
      "board.workflow.graph.approve" =>
        workflow_view_outcome(self.board.graph_decision(grant=true))
      "board.workflow.graph.reject" =>
        workflow_view_outcome(self.board.graph_decision(grant=false))
      "board.workflow.propose" => self.propose_guided()
      "board.workflow.prepare" => self.prepare_guided()
      "board.workflow.move" => self.move_guided()
      "board.workflow.scope.approve" | "board.workflow.scope.reject" =>
        self.scope_guided(action == "board.workflow.scope.approve")
      _ => self.board.invoke(action, args)
    }
    self.present(result)
  } catch {
    WorkflowNavigationCancelled | @posoco.UiError::Cancelled =>
      self.present(workflow_view_outcome(self.board.view())) catch {
        _ =>
          @posoco.CommandOutcome::Failure(reason="workflow_status_unavailable")
      }
    WorkflowNavigationError(reason) => @posoco.CommandOutcome::Failure(reason~)
    @posoco.UiError::Unsupported(_) =>
      @posoco.CommandOutcome::Failure(reason="trusted_ui_required")
    @posoco.UiError::InvalidRequest(_) =>
      @posoco.CommandOutcome::Failure(reason="workflow_ui_invalid_request")
    @posoco.UiError::IoFailure(detail="UI request timed out") =>
      @posoco.CommandOutcome::Failure(reason="workflow_ui_request_timed_out")
    @posoco.UiError::IoFailure(_) =>
      @posoco.CommandOutcome::Failure(reason="workflow_ui_request_failed")
    _ =>
      @posoco.CommandOutcome::Failure(
        reason="workflow_host_operation_failed_inspect_status_no_retry",
      )
  }
}
