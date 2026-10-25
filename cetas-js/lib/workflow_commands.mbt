///|
/// Product navigation only. Board retains every approval, mutation and lifecycle
/// barrier; this facade replaces its command presentation, not its runtime.
priv struct CetasWorkflowCommands {
  board : @board.BoardWorkflows
  agents : CetasWorkflowAgents
  settings : @cetas_core.CetasWorkflowSettings
  tickets : TicketRuntime?
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
    tools=[self],
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
/// Board command ids are internal. `/board` is a terminal-local route, not a
/// command, so every Board definition — including the workflow menu — stays
/// registered and callable by canonical id while no longer being
/// user-discoverable.
fn is_board_command_id(id : String) -> Bool {
  id == "board" || id.has_prefix("board.")
}

///|
impl @posoco.CommandPort for CetasWorkflowCommands with fn commands(self) {
  let definitions = self.board
    .commands()
    .map(def => {
      if is_board_command_id(def.id) {
        { ..def, aliases: [], visible: false, }
      } else {
        def
      }
    })
  // Board command ids stay registered — the host and the dashboard invoke them
  // by canonical id — but none of them is a user-facing slash command.
  definitions.push(@posoco.CommandDef::{
    id: "board.wire.ready",
    label: "Board wire ready",
    description: "Internal: attach the Board backend before serving the dashboard",
    category: "board",
    ctype: @posoco.CommandType::Action,
    params: [],
    aliases: [],
    shortcut: None,
    icon: None,
    visible: false,
    metadata: None,
  })
  definitions.push(@posoco.CommandDef::{
    id: "board.wire.snapshot",
    label: "Board wire snapshot",
    description: "Internal: authoritative Board snapshot for the dashboard",
    category: "board",
    ctype: @posoco.CommandType::Action,
    params: [],
    aliases: [],
    shortcut: None,
    icon: None,
    visible: false,
    metadata: None,
  })
  definitions.push(@posoco.CommandDef::{
    id: "board.wire.command",
    label: "Board wire command",
    description: "Internal: one Board wire command from the dashboard",
    category: "board",
    ctype: @posoco.CommandType::Action,
    params: [],
    aliases: [],
    shortcut: None,
    icon: None,
    visible: false,
    metadata: None,
  })
  definitions.push(@posoco.CommandDef::{
    id: "board.ticket.run_ready",
    label: "Run next ready ticket",
    description: "Internal: start the next Ready Board ticket as a background worker session",
    category: "board",
    ctype: @posoco.CommandType::Action,
    params: [],
    aliases: [],
    shortcut: None,
    icon: None,
    visible: false,
    metadata: None,
  })
  definitions.push(@posoco.CommandDef::{
    id: "board.ticket.state",
    label: "Board ticket state",
    description: "Internal: open ticket questions and background runs",
    category: "board",
    ctype: @posoco.CommandType::Action,
    params: [],
    aliases: [],
    shortcut: None,
    icon: None,
    visible: false,
    metadata: None,
  })
  definitions.push(@posoco.CommandDef::{
    id: "board.ticket.answer",
    label: "Answer ticket question",
    description: "Internal: answer one Board ticket question",
    category: "board",
    ctype: @posoco.CommandType::Action,
    params: [],
    aliases: [],
    shortcut: None,
    icon: None,
    visible: false,
    metadata: None,
  })
  definitions.push(@posoco.CommandDef::{
    id: "board.ticket.set_model",
    label: "Pin ticket model",
    description: "Internal: pin or clear one Board ticket's model and effort",
    category: "board",
    ctype: @posoco.CommandType::Action,
    params: [],
    aliases: [],
    shortcut: None,
    icon: None,
    visible: false,
    metadata: None,
  })
  definitions.push(@posoco.CommandDef::{
    id: "board.ticket.shape",
    label: "Shape ticket",
    description: "Internal: clarify and refine one Board ticket before work",
    category: "board",
    ctype: @posoco.CommandType::Action,
    params: [],
    aliases: [],
    shortcut: None,
    icon: None,
    visible: false,
    metadata: None,
  })
  definitions.push(@posoco.CommandDef::{
    id: "board.ticket.run",
    label: "Run ticket",
    description: "Internal: start one Ready Board ticket as a background worker",
    category: "board",
    ctype: @posoco.CommandType::Action,
    params: [],
    aliases: [],
    shortcut: None,
    icon: None,
    visible: false,
    metadata: None,
  })
  definitions.push(@posoco.CommandDef::{
    id: "board.ticket.retry",
    label: "Retry ticket",
    description: "Internal: restart one Ready, Review, or Suspended ticket as a fresh background worker",
    category: "board",
    ctype: @posoco.CommandType::Action,
    params: [],
    aliases: [],
    shortcut: None,
    icon: None,
    visible: false,
    metadata: None,
  })
  definitions.push(@posoco.CommandDef::{
    id: "board.ticket.request_changes",
    label: "Request ticket changes",
    description: "Internal: send one Review ticket back to Ready with reviewer feedback and a fresh worker",
    category: "board",
    ctype: @posoco.CommandType::Action,
    params: [],
    aliases: [],
    shortcut: None,
    icon: None,
    visible: false,
    metadata: None,
  })
  definitions.push(@posoco.CommandDef::{
    id: "board.ticket.resume",
    label: "Resume ticket",
    description: "Internal: continue one interrupted ticket from its durable child session",
    category: "board",
    ctype: @posoco.CommandType::Action,
    params: [],
    aliases: [],
    shortcut: None,
    icon: None,
    visible: false,
    metadata: None,
  })
  definitions.push(@posoco.CommandDef::{
    id: "board.ticket.dismiss_progress",
    label: "Dismiss ticket updates",
    description: "Internal: clear Inbox progress updates without changing any ticket",
    category: "board",
    ctype: @posoco.CommandType::Action,
    params: [],
    aliases: [],
    shortcut: None,
    icon: None,
    visible: false,
    metadata: None,
  })
  definitions.push(@posoco.CommandDef::{
    id: "board.ticket.dismiss",
    label: "Dismiss ticket result",
    description: "Internal: clear one completed ticket result from the inbox",
    category: "board",
    ctype: @posoco.CommandType::Action,
    params: [],
    aliases: [],
    shortcut: None,
    icon: None,
    visible: false,
    metadata: None,
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
            choices.push(
              (
                "continue", "Continue approved Tasks — prepare and execute one wave",
              ),
            )
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
/// Parse the `board.ticket.set_model` model argument: `null` (explicit
/// inherit) or `{"slot": "...", "effort": null|"..."}`. Unknown fields are
/// rejected rather than dropped, so a host typo can never be written as a
/// silent inheritance. Catalog membership is validated later, against the
/// manager's current state — not here, where no catalog is available.
fn parse_ticket_model_arg(value : Json) -> Result[TicketModelChoice?, String] {
  match value {
    Json::Null => Ok(None)
    Json::Object(model) => {
      for key in model.keys() {
        if key != "slot" && key != "effort" {
          return Err("unknown ticket model field: " + key)
        }
      }
      let slot = match model.get("slot") {
        Some(Json::String(value)) if !value.trim().is_empty() => value
        _ => return Err("ticket model slot must be a non-empty string")
      }
      let effort = match model.get("effort") {
        Some(Json::Null) | None => None
        Some(Json::String(value)) if !value.trim().is_empty() => Some(value)
        Some(_) => return Err("ticket model effort must be a string or null")
      }
      Ok(Some({ slot, effort, }))
    }
    _ => Err("ticket model must be an object or null")
  }
}

///|
impl @posoco.CommandPort for CetasWorkflowCommands with fn invoke(
  self,
  id,
  args,
) {
  if id == "board.ticket.state" {
    let tickets = match self.tickets {
      Some(tickets) => tickets
      None =>
        return @posoco.CommandOutcome::Failure(
          reason="ticket_runtime_unavailable",
        )
    }
    tickets.reconcile_interrupted() catch {
      _ => return @posoco.CommandOutcome::Failure(reason="ticket_state_failed")
    }
    return @posoco.CommandOutcome::Success(
      feedback="",
      structured=Some(tickets.state_json()),
      ui_hint=Some(@posoco.UiHint::None),
    )
  }
  if id == "board.ticket.set_model" {
    let tickets = match self.tickets {
      Some(tickets) => tickets
      None =>
        return @posoco.CommandOutcome::Failure(
          reason="ticket_runtime_unavailable",
        )
    }
    let fields = match args {
      Object(fields) => fields
      _ =>
        return @posoco.CommandOutcome::Failure(
          reason="invalid_ticket_set_model",
        )
    }
    let task_id = match fields.get("task_id") {
      Some(String(value)) if !value.trim().is_empty() => value
      _ =>
        return @posoco.CommandOutcome::Failure(
          reason="invalid_ticket_set_model",
        )
    }
    // `model` must be stated: `null` is the explicit inherit ("clear the
    // pin"), an object is the pin. A missing key is a malformed request, not
    // an implicit clear.
    let model = match fields.get("model") {
      Some(value) =>
        match parse_ticket_model_arg(value) {
          Ok(model) => model
          Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
        }
      None =>
        return @posoco.CommandOutcome::Failure(
          reason="invalid_ticket_set_model",
        )
    }
    let updated = tickets.set_model(task_id, model) catch {
      _ =>
        return @posoco.CommandOutcome::Failure(reason="ticket_set_model_failed")
    }
    match updated {
      Ok(state) =>
        return @posoco.CommandOutcome::Success(
          feedback="Ticket model updated.",
          structured=Some(state),
          ui_hint=Some(@posoco.UiHint::None),
        )
      Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
    }
  }
  if id == "board.ticket.shape" {
    let tickets = match self.tickets {
      Some(tickets) => tickets
      None =>
        return @posoco.CommandOutcome::Failure(
          reason="ticket_runtime_unavailable",
        )
    }
    let task_id = match args {
      Object(fields) =>
        match fields.get("task_id") {
          Some(String(value)) => value
          _ =>
            return @posoco.CommandOutcome::Failure(
              reason="invalid_ticket_shape",
            )
        }
      _ => return @posoco.CommandOutcome::Failure(reason="invalid_ticket_shape")
    }
    let shaped = tickets.shape(task_id) catch {
      _ => return @posoco.CommandOutcome::Failure(reason="ticket_shape_failed")
    }
    match shaped {
      Ok(_) =>
        return @posoco.CommandOutcome::Success(
          feedback="Ticket shaping started in the background.",
          structured=Some(tickets.state_json()),
          ui_hint=Some(@posoco.UiHint::None),
        )
      Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
    }
  }
  if id == "board.ticket.run" {
    let tickets = match self.tickets {
      Some(tickets) => tickets
      None =>
        return @posoco.CommandOutcome::Failure(
          reason="ticket_runtime_unavailable",
        )
    }
    let task_id = match args {
      Object(fields) =>
        match fields.get("task_id") {
          Some(String(value)) => value
          _ =>
            return @posoco.CommandOutcome::Failure(reason="invalid_ticket_run")
        }
      _ => return @posoco.CommandOutcome::Failure(reason="invalid_ticket_run")
    }
    let ran = tickets.run(task_id) catch {
      _ => return @posoco.CommandOutcome::Failure(reason="ticket_start_failed")
    }
    match ran {
      Ok(_) =>
        return @posoco.CommandOutcome::Success(
          feedback="Ticket started in the background.",
          structured=Some(tickets.state_json()),
          ui_hint=Some(@posoco.UiHint::None),
        )
      Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
    }
  }
  if id == "board.ticket.retry" {
    let tickets = match self.tickets {
      Some(tickets) => tickets
      None =>
        return @posoco.CommandOutcome::Failure(
          reason="ticket_runtime_unavailable",
        )
    }
    let task_id = match args {
      Object(fields) =>
        match fields.get("task_id") {
          Some(String(value)) if !value.trim().is_empty() => value
          _ =>
            return @posoco.CommandOutcome::Failure(
              reason="invalid_ticket_retry",
            )
        }
      _ => return @posoco.CommandOutcome::Failure(reason="invalid_ticket_retry")
    }
    let retried = tickets.retry(task_id) catch {
      _ => return @posoco.CommandOutcome::Failure(reason="ticket_retry_failed")
    }
    match retried {
      Ok(state) =>
        return @posoco.CommandOutcome::Success(
          feedback="Ticket retried with a fresh background worker.",
          structured=Some(state),
          ui_hint=Some(@posoco.UiHint::None),
        )
      Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
    }
  }
  if id == "board.ticket.request_changes" {
    let tickets = match self.tickets {
      Some(tickets) => tickets
      None =>
        return @posoco.CommandOutcome::Failure(
          reason="ticket_runtime_unavailable",
        )
    }
    let fields = match args {
      Object(fields) => fields
      _ =>
        return @posoco.CommandOutcome::Failure(
          reason="invalid_ticket_request_changes",
        )
    }
    let task_id = match fields.get("task_id") {
      Some(String(value)) if !value.trim().is_empty() => value
      _ =>
        return @posoco.CommandOutcome::Failure(
          reason="invalid_ticket_request_changes",
        )
    }
    // Reviewer feedback is the requirement the next attempt must address; a
    // missing or blank body is a malformed request, never an empty review.
    let feedback = match fields.get("feedback") {
      Some(String(value)) if !value.trim().is_empty() => value
      _ =>
        return @posoco.CommandOutcome::Failure(
          reason="invalid_ticket_request_changes",
        )
    }
    let updated = tickets.request_changes(task_id, feedback) catch {
      _ =>
        return @posoco.CommandOutcome::Failure(
          reason="ticket_request_changes_failed",
        )
    }
    match updated {
      Ok(state) =>
        return @posoco.CommandOutcome::Success(
          feedback="Changes requested; the ticket is Ready for a fresh worker.",
          structured=Some(state),
          ui_hint=Some(@posoco.UiHint::None),
        )
      Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
    }
  }
  if id == "board.ticket.resume" {
    let tickets = match self.tickets {
      Some(tickets) => tickets
      None =>
        return @posoco.CommandOutcome::Failure(
          reason="ticket_runtime_unavailable",
        )
    }
    let task_id = match args {
      Object(fields) =>
        match fields.get("task_id") {
          Some(String(value)) if !value.trim().is_empty() => value
          _ =>
            return @posoco.CommandOutcome::Failure(
              reason="invalid_ticket_resume",
            )
        }
      _ =>
        return @posoco.CommandOutcome::Failure(reason="invalid_ticket_resume")
    }
    let resumed = tickets.resume_ticket(task_id) catch {
      _ => return @posoco.CommandOutcome::Failure(reason="ticket_resume_failed")
    }
    match resumed {
      Ok(state) =>
        return @posoco.CommandOutcome::Success(
          feedback="Ticket resumed from its durable session.",
          structured=Some(state),
          ui_hint=Some(@posoco.UiHint::None),
        )
      Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
    }
  }
  if id == "board.ticket.dismiss_progress" {
    let tickets = match self.tickets {
      Some(tickets) => tickets
      None =>
        return @posoco.CommandOutcome::Failure(
          reason="ticket_runtime_unavailable",
        )
    }
    let task_id = match args {
      Object(fields) =>
        match fields.get("task_id") {
          Some(String(value)) if !value.trim().is_empty() => Some(value)
          _ => None
        }
      _ => None
    }
    return @posoco.CommandOutcome::Success(
      feedback="Updates dismissed.",
      structured=Some(tickets.dismiss_progress(task_id)),
      ui_hint=Some(@posoco.UiHint::None),
    )
  }
  if id == "board.ticket.dismiss" {
    let tickets = match self.tickets {
      Some(tickets) => tickets
      None =>
        return @posoco.CommandOutcome::Failure(
          reason="ticket_runtime_unavailable",
        )
    }
    let task_id = match args {
      Object(fields) =>
        match fields.get("task_id") {
          Some(String(value)) => value
          _ =>
            return @posoco.CommandOutcome::Failure(
              reason="invalid_ticket_dismiss",
            )
        }
      _ =>
        return @posoco.CommandOutcome::Failure(reason="invalid_ticket_dismiss")
    }
    tickets.dismiss(task_id)
    return @posoco.CommandOutcome::Success(
      feedback="",
      structured=Some(tickets.state_json()),
      ui_hint=Some(@posoco.UiHint::None),
    )
  }
  if id == "board.ticket.run_ready" {
    let tickets = match self.tickets {
      Some(tickets) => tickets
      None =>
        return @posoco.CommandOutcome::Failure(
          reason="ticket_runtime_unavailable",
        )
    }
    let ran = tickets.run_ready() catch {
      _ => return @posoco.CommandOutcome::Failure(reason="ticket_start_failed")
    }
    match ran {
      Ok(_) =>
        return @posoco.CommandOutcome::Success(
          feedback="Ready tickets started in the background.",
          structured=Some(tickets.state_json()),
          ui_hint=Some(@posoco.UiHint::None),
        )
      Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
    }
  }
  if id == "board.ticket.answer" {
    let tickets = match self.tickets {
      Some(tickets) => tickets
      None =>
        return @posoco.CommandOutcome::Failure(
          reason="ticket_runtime_unavailable",
        )
    }
    let fields = match args {
      Object(fields) => fields
      _ =>
        return @posoco.CommandOutcome::Failure(reason="invalid_ticket_answer")
    }
    let question_id = match fields.get("question_id") {
      Some(String(value)) => value
      _ =>
        return @posoco.CommandOutcome::Failure(reason="invalid_ticket_answer")
    }
    let response = match fields.get("text") {
      Some(String(value)) => Some(@posoco.UiResponse::Text(value))
      _ =>
        match fields.get("confirm") {
          Some(True) => Some(@posoco.UiResponse::Yes)
          Some(False) => Some(@posoco.UiResponse::No)
          _ =>
            match fields.get("index") {
              Some(Number(value, ..)) =>
                Some(@posoco.UiResponse::Selected(value.to_int()))
              _ => None
            }
        }
    }
    let response = match response {
      Some(response) => response
      None =>
        return @posoco.CommandOutcome::Failure(reason="invalid_ticket_answer")
    }
    match tickets.questions.answer(question_id, response) {
      Ok(_) =>
        return @posoco.CommandOutcome::Success(
          feedback="Answer sent.",
          structured=Some(tickets.state_json()),
          ui_hint=Some(@posoco.UiHint::None),
        )
      Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
    }
  }
  if id == "board.wire.ready" {
    let ready = self.board.wire_ready() catch {
      _ =>
        return @posoco.CommandOutcome::Failure(reason="board_wire_unavailable")
    }
    match ready {
      Ok(_) =>
        return @posoco.CommandOutcome::Success(
          feedback="",
          structured=None,
          ui_hint=Some(@posoco.UiHint::None),
        )
      Err(error) => return @posoco.CommandOutcome::Failure(reason=error.code())
    }
  }
  if id == "board.wire.snapshot" {
    let snapshot = self.board.wire_snapshot() catch {
      _ =>
        return @posoco.CommandOutcome::Failure(reason="board_wire_unavailable")
    }
    match snapshot {
      Ok(frame) => {
        let structured : Json = { "frame": Json::string(frame) }
        return @posoco.CommandOutcome::Success(
          feedback="",
          structured=Some(structured),
          ui_hint=Some(@posoco.UiHint::None),
        )
      }
      Err(error) => return @posoco.CommandOutcome::Failure(reason=error.code())
    }
  }
  if id == "board.wire.command" {
    let raw = match args {
      Object(fields) =>
        match fields.get("frame") {
          Some(String(value)) => value
          _ =>
            return @posoco.CommandOutcome::Failure(reason="invalid_board_frame")
        }
      _ => return @posoco.CommandOutcome::Failure(reason="invalid_board_frame")
    }
    let command = self.board.wire_command(raw) catch {
      _ =>
        return @posoco.CommandOutcome::Failure(reason="board_wire_unavailable")
    }
    match command {
      Ok(frame) => {
        let structured : Json = { "frame": Json::string(frame) }
        return @posoco.CommandOutcome::Success(
          feedback="",
          structured=Some(structured),
          ui_hint=Some(@posoco.UiHint::None),
        )
      }
      Err(error) => return @posoco.CommandOutcome::Failure(reason=error.code())
    }
  }
  // The user supplies the highest-level goal once. Starting and planning
  // remain separately confirmed by the existing Board trusted UI.
  if id == "board.workflow" && args is { "goal": String(goal), .. } {
    if goal.trim().is_empty() || goal.length() > 256 {
      return @posoco.CommandOutcome::Failure(reason="invalid_workflow_goal")
    }
    if (self.agents.parent_mode)() == @permission.ReadOnly {
      return @posoco.CommandOutcome::Failure(reason="approval_denied")
    }
    let started = self.board.start(title=goal) catch {
      _ =>
        return @posoco.CommandOutcome::Failure(
          reason="workflow_start_failed_inspect_status",
        )
    }
    match started {
      Err(error) => return @posoco.CommandOutcome::Failure(reason=error.code())
      Ok(view) => {
        guard view.run is Some(run) && !run.scope.is_empty() else {
          return @posoco.CommandOutcome::Failure(
            reason="workflow_start_missing_scope",
          )
        }
        let proposed = self.board.propose(
          parent=run.scope[0],
          requirements=goal,
        ) catch {
          _ =>
            return @posoco.CommandOutcome::Failure(
              reason="planning_failed_inspect_status_no_retry",
            )
        }
        match proposed {
          Ok(preview) =>
            return @posoco.CommandOutcome::Success(
              feedback="Planning complete. Review the graph proposal, then approve graph and execution scope separately through the Board workflow commands.",
              structured=Some(preview),
              ui_hint=Some(@posoco.UiHint::None),
            )
          Err(error) =>
            return @posoco.CommandOutcome::Failure(
              reason="workflow_started_planning_failed_" +
                error.code() +
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
    let action = if id == "board.workflow" {
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
      "board.workflow.continue" => self.continue_guided()
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

///|
/// Read-only Board provenance for the parent Agent: one `board_work` tool with
/// three queries — what the Board holds now, which ticket's committed
/// ReviewReport mentions a path or a ticket id, and one ticket's report. It only
/// reads the authoritative wire snapshot: no approval, no dispatch, no stage
/// move, and no provenance invented for a ticket whose report mentions none.
///
/// The Board itself is unbounded; a tool reply is not, so every list answer is
/// bounded by the limits below.
let board_work_limit_default : Int32 = 10

///|
/// Hard ceiling on rendered tickets, whatever the model asks for.
let board_work_limit_max : Int32 = 20

///|
/// The actions `board_work` accepts. Anything else is a reported tool error,
/// never an implicit status read.
let board_work_actions : Array[String] = ["status", "history", "review"]

///|
fn board_work_schema() -> Json {
  Json::object({
    "type": Json::string("object"),
    "properties": Json::object({
      "action": Json::object({
        "type": Json::string("string"),
        "enum": Json::array(board_work_actions.map(Json::string)),
        "description": Json::string(
          "status (current tickets), history (tickets whose committed review mentions a path or a ticket id), or review (one ticket's review report and review feedback)",
        ),
      }),
      "path": Json::object({
        "type": Json::string("string"),
        "description": Json::string(
          "history: case-insensitive substring matched against a review report's changes and artifacts",
        ),
      }),
      "ticket": Json::object({
        "type": Json::string("string"),
        "description": Json::string(
          "ticket id: required for review, and one way to select history",
        ),
      }),
      "limit": Json::object({
        "type": Json::string("number"),
        "description": Json::string(
          "maximum tickets rendered; default 10, clamped to 1..20",
        ),
      }),
    }),
    "required": Json::array([Json::string("action")]),
  })
}

///|
fn board_work_tool_def() -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked("board_work"),
    description: "Read Board provenance. action=status lists current tickets (id, title, stage, priority, review summary); action=history finds tickets whose committed review changes or artifacts mention a path (case-insensitive) or a ticket id; action=review returns one ticket's review report and review feedback. Read-only: it never creates, moves, runs, approves or retires Board work, and a ticket with no report has no file provenance.",
    input_schema: board_work_schema(),
    owner: @posoco.OwnerId::unchecked("cetas_board"),
    policy: @posoco.ExecutionPolicy::Sequential,
    provenance: Some("cetas_board"),
  }
}

///|
impl @posoco.ToolProvider for CetasWorkflowCommands with fn list_tools(
  _self : CetasWorkflowCommands,
) -> Array[@posoco.ToolDef] {
  [board_work_tool_def()]
}

///|
/// One parsed `board_work` call. `limit` is already clamped to the declared
/// range.
priv struct BoardWorkQuery {
  action : String
  path : String?
  ticket : String?
  limit : Int32
}

///|
fn parse_board_work_arguments(
  arguments : Json,
) -> Result[BoardWorkQuery, String] {
  let fields = match arguments {
    Object(fields) => fields
    _ => return Err("board_work: arguments must be a JSON object")
  }
  let action = match fields.get("action") {
    Some(String(value)) => value.trim().to_owned()
    Some(_) => return Err("board_work: 'action' must be a string")
    None => return Err("board_work: 'action' is required")
  }
  if !board_work_actions.contains(action) {
    return Err(
      "board_work: 'action' must be one of " + board_work_actions.join(", "),
    )
  }
  let path = match fields.get("path") {
    None | Some(Null) => None
    Some(String(value)) =>
      if value.trim().is_empty() {
        return Err("board_work: 'path' must be a non-empty string")
      } else {
        Some(value.trim().to_owned())
      }
    Some(_) => return Err("board_work: 'path' must be a string")
  }
  let ticket = match fields.get("ticket") {
    None | Some(Null) => None
    Some(String(value)) =>
      if value.trim().is_empty() {
        return Err("board_work: 'ticket' must be a non-empty string")
      } else {
        Some(value.trim().to_owned())
      }
    Some(_) => return Err("board_work: 'ticket' must be a string")
  }
  let limit = match fields.get("limit") {
    None | Some(Null) => board_work_limit_default
    Some(Number(value, ..)) => {
      let requested = value.to_int()
      if requested < 1 {
        1
      } else if requested > board_work_limit_max {
        board_work_limit_max
      } else {
        requested
      }
    }
    Some(_) => return Err("board_work: 'limit' must be a number")
  }
  // A history with no filter would be a whole-board dump; the caller must
  // name what it is looking for.
  if action == "history" && path is None && ticket is None {
    return Err("board_work: 'history' needs 'path' or 'ticket'")
  }
  Ok({ action, path, ticket, limit, })
}

///|
/// One committed Board ticket as `board_work` reads it. Everything here comes
/// from the authoritative snapshot: a ticket with no report has no provenance,
/// and none is inferred from its title, stage or a transcript.
priv struct BoardWorkTicket {
  id : String
  title : String
  stage : String
  priority : String
  review : Json?
  review_feedback : String?
}

///|
/// One string field of a committed task. A wrong type or a missing key is a
/// malformed snapshot, not a silent default.
fn board_work_task_string(
  fields : Map[String, Json],
  key : String,
) -> Result[String, String] {
  match fields.get(key) {
    Some(String(value)) => Ok(value)
    Some(_) =>
      Err("board_work: Board snapshot task '" + key + "' is not a string")
    None => Err("board_work: Board snapshot task has no '" + key + "'")
  }
}

///|
/// The committed ReviewReport of one ticket, validated only where `board_work`
/// interprets it: the outcome and summary are strings, `changes` is a string
/// array and every artifact names its kind, label and reference. The rest of
/// the report passes through exactly as the Board committed it.
fn board_work_task_review(value : Json) -> Result[Json, String] {
  let fields = match value {
    Object(fields) => fields
    _ => return Err("board_work: Board snapshot task review is not an object")
  }
  for key in ["outcome", "summary"] {
    match fields.get(key) {
      Some(String(_)) => ()
      _ =>
        return Err(
          "board_work: Board snapshot task review has no string '" + key + "'",
        )
    }
  }
  match fields.get("changes") {
    Some(Array(changes)) =>
      for change in changes {
        if !(change is String(_)) {
          return Err(
            "board_work: Board snapshot task review 'changes' entry is not a string",
          )
        }
      }
    _ =>
      return Err(
        "board_work: Board snapshot task review has no 'changes' array",
      )
  }
  match fields.get("artifacts") {
    Some(Array(artifacts)) =>
      for artifact in artifacts {
        match artifact {
          Object(artifact_fields) =>
            for key in ["kind", "label", "uri_or_digest"] {
              match artifact_fields.get(key) {
                Some(String(_)) => ()
                _ =>
                  return Err(
                    "board_work: Board snapshot task review artifact has no string '" +
                    key +
                    "'",
                  )
              }
            }
          _ =>
            return Err(
              "board_work: Board snapshot task review artifact is not an object",
            )
        }
      }
    _ =>
      return Err(
        "board_work: Board snapshot task review has no 'artifacts' array",
      )
  }
  Ok(value)
}

///|
fn board_work_ticket(value : Json) -> Result[BoardWorkTicket, String] {
  let fields = match value {
    Object(fields) => fields
    _ => return Err("board_work: Board snapshot task is not an object")
  }
  let id = match board_work_task_string(fields, "id") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let title = match board_work_task_string(fields, "title") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let stage = match board_work_task_string(fields, "stage") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let priority = match board_work_task_string(fields, "priority") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let review : Json? = match fields.get("review") {
    None | Some(Null) => None
    Some(report) =>
      match board_work_task_review(report) {
        Ok(report) => Some(report)
        Err(reason) => return Err(reason)
      }
  }
  let review_feedback : String? = match fields.get("review_feedback") {
    None | Some(Null) => None
    Some(String(text)) => Some(text)
    Some(_) =>
      return Err(
        "board_work: Board snapshot task review_feedback is not a string",
      )
  }
  Ok({ id, title, stage, priority, review, review_feedback, })
}

///|
/// The durable Board state one `board_work` call reads: the committed revision
/// and its tickets.
priv struct BoardWorkSnapshot {
  revision : Json
  tickets : Array[BoardWorkTicket]
}

///|
/// Parse `payload.board.tasks` out of one encoded snapshot frame. The frame is
/// the only source: a frame that is not a snapshot carrying a board task array
/// is an error the model must see, never an empty board.
fn board_work_snapshot(frame : String) -> Result[BoardWorkSnapshot, String] {
  let root = @json.parse(frame) catch {
    _ => return Err("board_work: Board snapshot is not valid JSON")
  }
  let payload = match root {
    Object(fields) =>
      match fields.get("payload") {
        Some(Object(payload)) => payload
        _ => return Err("board_work: Board snapshot has no payload object")
      }
    _ => return Err("board_work: Board snapshot is not an object")
  }
  let board = match payload.get("board") {
    Some(Object(board)) => board
    _ => return Err("board_work: Board snapshot payload has no board object")
  }
  let revision = board.get("revision").unwrap_or(Json::null())
  let tasks = match board.get("tasks") {
    Some(Array(tasks)) => tasks
    _ => return Err("board_work: Board snapshot board has no tasks array")
  }
  let tickets : Array[BoardWorkTicket] = []
  for task in tasks {
    match board_work_ticket(task) {
      Ok(ticket) => tickets.push(ticket)
      Err(reason) => return Err(reason)
    }
  }
  Ok({ revision, tickets, })
}

///|
/// One string field of a committed review report, if the ticket has a report.
fn board_work_review_text(review : Json?, key : String) -> String? {
  match review {
    Some(Object(fields)) =>
      match fields.get(key) {
        Some(String(value)) => Some(value)
        _ => None
      }
    _ => None
  }
}

///|
/// The string entries of one string-array review field.
fn board_work_review_strings(review : Json?, key : String) -> Array[String] {
  let entries : Array[String] = []
  match review {
    Some(Object(fields)) =>
      match fields.get(key) {
        Some(Array(values)) =>
          for value in values {
            match value {
              String(text) => entries.push(text)
              _ => ()
            }
          }
        _ => ()
      }
    _ => ()
  }
  entries
}

///|
/// The committed artifacts of one review report, in committed order.
fn board_work_review_artifacts(review : Json?) -> Array[Json] {
  match review {
    Some(Object(fields)) =>
      match fields.get("artifacts") {
        Some(Array(artifacts)) => artifacts
        _ => []
      }
    _ => []
  }
}

///|
/// Whether one committed review report mentions `needle` (already lowercase) in
/// a change or in an artifact reference. Nothing else is searched: provenance
/// comes from the report the Board committed, never from a title or a
/// transcript.
fn board_work_mentions(review : Json?, needle : String) -> Bool {
  for change in board_work_review_strings(review, "changes") {
    if change.to_lower().contains(needle) {
      return true
    }
  }
  for artifact in board_work_review_artifacts(review) {
    match artifact {
      Object(fields) =>
        for key in ["label", "uri_or_digest"] {
          match fields.get(key) {
            Some(String(value)) =>
              if value.to_lower().contains(needle) {
                return true
              }
            _ => ()
          }
        }
      _ => ()
    }
  }
  false
}

///|
/// One artifact rendered as a short, terminal-safe reference.
fn board_work_artifact_label(artifact : Json) -> String {
  match artifact {
    Object(fields) => {
      let kind = match fields.get("kind") {
        Some(String(value)) => value
        _ => "artifact"
      }
      let label = match fields.get("label") {
        Some(String(value)) => value
        _ => ""
      }
      let reference = match fields.get("uri_or_digest") {
        Some(String(value)) => value
        _ => ""
      }
      workflow_label(kind + " " + label + " (" + reference + ")")
    }
    _ => "artifact"
  }
}

///|
/// The human-readable description of the history filter, mirrored in the text
/// reply so the model can see exactly what it asked for.
fn board_work_filter_label(path : String?, ticket : String?) -> String {
  let parts : Array[String] = []
  match path {
    Some(value) => parts.push("path \"" + workflow_label(value) + "\"")
    None => ()
  }
  match ticket {
    Some(value) => parts.push("ticket \"" + workflow_label(value) + "\"")
    None => ()
  }
  if parts.is_empty() {
    "no filter"
  } else {
    parts.join(" or ")
  }
}

///|
/// One bounded status row: identity, stage, priority and the review summary the
/// Board committed, if any.
fn board_work_status_row(ticket : BoardWorkTicket) -> Json {
  Json::object({
    "id": Json::string(ticket.id),
    "title": Json::string(ticket.title),
    "stage": Json::string(ticket.stage),
    "priority": Json::string(ticket.priority),
    "review_summary": match board_work_review_text(ticket.review, "summary") {
      Some(summary) => Json::string(summary)
      None => Json::null()
    },
  })
}

///|
fn board_work_status(
  snapshot : BoardWorkSnapshot,
  limit : Int32,
) -> (Json, String) {
  let total = snapshot.tickets.length()
  let returned = if total < limit { total } else { limit }
  let revision = snapshot.revision.stringify()
  let text = StringBuilder()
  if total == 0 {
    text.write_string(
      "Board revision " + revision + ": no tickets. Nothing was changed.\n",
    )
  } else {
    text.write_string(
      "Board revision " +
      revision +
      ": showing " +
      returned.to_string() +
      " of " +
      total.to_string() +
      " tickets. Nothing was changed.\n",
    )
  }
  let rows : Array[Json] = []
  for index in 0..<returned {
    let ticket = snapshot.tickets[index]
    rows.push(board_work_status_row(ticket))
    text.write_string(
      "- " +
      workflow_label(ticket.id) +
      " [" +
      ticket.stage +
      "] " +
      ticket.priority +
      " — " +
      workflow_label(ticket.title) +
      "\n",
    )
    match board_work_review_text(ticket.review, "summary") {
      Some(summary) =>
        text.write_string("  review: " + workflow_label(summary) + "\n")
      None => ()
    }
  }
  (
    Json::object({
      "action": Json::string("status"),
      "revision": snapshot.revision,
      "total": Json::number(total.to_double()),
      "returned": Json::number(returned.to_double()),
      "limit": Json::number(limit.to_double()),
      "tasks": Json::array(rows),
    }),
    text.to_string(),
  )
}

///|
fn board_work_history(
  snapshot : BoardWorkSnapshot,
  limit : Int32,
  path : String?,
  ticket : String?,
) -> (Json, String) {
  let needle = match path {
    Some(value) => Some(value.to_lower())
    None => None
  }
  let matched : Array[BoardWorkTicket] = []
  for entry in snapshot.tickets {
    let by_ticket = match ticket {
      Some(id) => entry.id == id
      None => false
    }
    let by_path = match needle {
      Some(needle) => board_work_mentions(entry.review, needle)
      None => false
    }
    if by_ticket || by_path {
      matched.push(entry)
    }
  }
  let returned = if matched.length() < limit { matched.length() } else { limit }
  let filter = board_work_filter_label(path, ticket)
  let text = StringBuilder()
  if matched.is_empty() {
    text.write_string(
      "No committed Board review matches " + filter + ". Nothing was changed.\n",
    )
  } else {
    text.write_string(
      "Board history matching " +
      filter +
      ": showing " +
      returned.to_string() +
      " of " +
      matched.length().to_string() +
      " tickets. Nothing was changed.\n",
    )
  }
  let rows : Array[Json] = []
  for index in 0..<returned {
    let entry = matched[index]
    rows.push(
      Json::object({
        "ticket": Json::string(entry.id),
        "title": Json::string(entry.title),
        "stage": Json::string(entry.stage),
        "review_summary": match
          board_work_review_text(entry.review, "summary") {
          Some(summary) => Json::string(summary)
          None => Json::null()
        },
        "changes": Json::array(
          board_work_review_strings(entry.review, "changes").map(Json::string),
        ),
        "artifacts": Json::array(board_work_review_artifacts(entry.review)),
        "review_feedback": match entry.review_feedback {
          Some(feedback) => Json::string(feedback)
          None => Json::null()
        },
      }),
    )
    text.write_string(
      "- " +
      workflow_label(entry.id) +
      " [" +
      entry.stage +
      "] " +
      workflow_label(entry.title) +
      "\n",
    )
    match board_work_review_text(entry.review, "summary") {
      Some(summary) =>
        text.write_string("  review: " + workflow_label(summary) + "\n")
      None => ()
    }
    for change in board_work_review_strings(entry.review, "changes") {
      text.write_string("  change: " + workflow_label(change) + "\n")
    }
    for artifact in board_work_review_artifacts(entry.review) {
      text.write_string(
        "  artifact: " + board_work_artifact_label(artifact) + "\n",
      )
    }
    match entry.review_feedback {
      Some(feedback) =>
        text.write_string("  feedback: " + workflow_label(feedback) + "\n")
      None => ()
    }
  }
  (
    Json::object({
      "action": Json::string("history"),
      "revision": snapshot.revision,
      "path": match path {
        Some(value) => Json::string(value)
        None => Json::null()
      },
      "ticket": match ticket {
        Some(value) => Json::string(value)
        None => Json::null()
      },
      "returned": Json::number(returned.to_double()),
      "matches": Json::array(rows),
    }),
    text.to_string(),
  )
}

///|
/// One ticket's committed ReviewReport and review feedback. A ticket the Board
/// does not hold is a reported error, not an empty report.
fn board_work_review(
  snapshot : BoardWorkSnapshot,
  ticket : String,
) -> Result[(Json, String), String] {
  let entry = match
    snapshot.tickets.iter().find_first(entry => entry.id == ticket) {
    Some(entry) => entry
    None =>
      return Err(
        "board_work: no Board ticket with id '" + workflow_label(ticket) + "'",
      )
  }
  let text = StringBuilder()
  text.write_string(
    "Ticket " +
    workflow_label(entry.id) +
    " [" +
    entry.stage +
    "] " +
    workflow_label(entry.title) +
    "\n",
  )
  match entry.review {
    Some(_) => {
      match board_work_review_text(entry.review, "outcome") {
        Some(outcome) =>
          text.write_string("outcome: " + workflow_label(outcome) + "\n")
        None => ()
      }
      match board_work_review_text(entry.review, "summary") {
        Some(summary) =>
          text.write_string("summary: " + workflow_label(summary) + "\n")
        None => ()
      }
      for change in board_work_review_strings(entry.review, "changes") {
        text.write_string("change: " + workflow_label(change) + "\n")
      }
      for artifact in board_work_review_artifacts(entry.review) {
        text.write_string(
          "artifact: " + board_work_artifact_label(artifact) + "\n",
        )
      }
    }
    None =>
      text.write_string("No review report is committed for this ticket.\n")
  }
  match entry.review_feedback {
    Some(feedback) =>
      text.write_string("review_feedback: " + workflow_label(feedback) + "\n")
    None => ()
  }
  Ok(
    (
      Json::object({
        "action": Json::string("review"),
        "ticket": Json::string(entry.id),
        "title": Json::string(entry.title),
        "stage": Json::string(entry.stage),
        "review": match entry.review {
          Some(report) => report
          None => Json::null()
        },
        "review_feedback": match entry.review_feedback {
          Some(feedback) => Json::string(feedback)
          None => Json::null()
        },
      }),
      text.to_string(),
    ),
  )
}

///|
/// One business-level failure the model can read and correct. Nothing was
/// changed by the failed call, and the Board is never repaired on its behalf.
fn board_work_reported(reason : String) -> @posoco.ToolOutcome {
  @posoco.ToolOutcome::ToolReportedError(content=reason, structured=None)
}

///|
impl @posoco.ToolProvider for CetasWorkflowCommands with fn execute(
  self : CetasWorkflowCommands,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let name = ctx.name.to_string()
  if name != "board_work" {
    raise @posoco.RuntimeError::UnknownTool(
      "cetas_board: unknown tool '" + name + "'",
    )
  }
  let query = match parse_board_work_arguments(ctx.arguments) {
    Ok(query) => query
    Err(reason) => return board_work_reported(reason)
  }
  // The same authoritative snapshot the Board dashboard reads: durable
  // committed data, read only. A missing snapshot is a visible error.
  let frame = self.board.wire_snapshot() catch {
    _ => return board_work_reported("board_work: Board snapshot unavailable")
  }
  let frame = match frame {
    Ok(frame) => frame
    Err(error) =>
      return board_work_reported(
        "board_work: Board snapshot unavailable (" + error.code() + ")",
      )
  }
  let snapshot = match board_work_snapshot(frame) {
    Ok(snapshot) => snapshot
    Err(reason) => return board_work_reported(reason)
  }
  let rendered : Result[(Json, String), String] = match query.action {
    "status" => Ok(board_work_status(snapshot, query.limit))
    "history" =>
      Ok(board_work_history(snapshot, query.limit, query.path, query.ticket))
    "review" =>
      match query.ticket {
        Some(ticket) => board_work_review(snapshot, ticket)
        None => Err("board_work: 'review' needs a 'ticket' id")
      }
    _ =>
      Err(
        "board_work: 'action' must be one of " + board_work_actions.join(", "),
      )
  }
  match rendered {
    Ok((structured, content)) =>
      @posoco.ToolOutcome::Success(content~, structured=Some(structured))
    Err(reason) => board_work_reported(reason)
  }
}
