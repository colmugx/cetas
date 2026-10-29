///|
priv struct TicketRuntime {
  board : @board.BoardWorkflows
  manager : ModelManagerFace
  parent_mode : () -> @permission.PermissionMode
  approval : &@permission.ApprovalSource?
  ctx : @cetas_core.HostContext
  group : @async.TaskGroup[Unit]
  questions : @work.TicketQuestions
  runs : @work.WorkRunStore
  progress : @work.WorkProgressLog
  child_store : CetasChildSessionStore
  session_root : String?
  mut counter : Int32
  mut reconciled : Bool
  mut resuming_task : String?
  mut team : TeamNames
  mut team_mcp : Map[String, TeamMcp]
  mut team_skills : Map[String, TeamSkills]
  mut profile : WorkProfile
  mcp : BoardMcp?
  skills : Array[BoardSkill]
}

///|
fn TicketRuntime::TicketRuntime(
  board~ : @board.BoardWorkflows,
  manager~ : ModelManagerFace,
  parent_mode~ : () -> @permission.PermissionMode,
  approval~ : &@permission.ApprovalSource?,
  ctx~ : @cetas_core.HostContext,
  group~ : @async.TaskGroup[Unit],
  session_root~ : String? = None,
  mcp~ : BoardMcp? = None,
  skills~ : Array[BoardSkill] = [],
  config~ : TeamConfig? = None,
) -> TicketRuntime {
  let config = match config {
    Some(value) => value
    None => TeamConfig::defaults()
  }
  {
    board,
    manager,
    parent_mode,
    approval,
    ctx,
    group,
    questions: @work.TicketQuestions::TicketQuestions(),
    runs: @work.WorkRunStore::WorkRunStore(),
    progress: @work.WorkProgressLog::WorkProgressLog(),
    child_store: CetasChildSessionStore::CetasChildSessionStore(),
    session_root,
    counter: 0,
    reconciled: false,
    resuming_task: None,
    team: config.names,
    team_mcp: config.mcp,
    team_skills: config.skills,
    profile: config.profile,
    mcp,
    skills,
  }
}

///|
fn TicketRuntime::child_store_for(
  self : TicketRuntime,
  task_id : String,
) -> CetasChildSessionStore {
  match self.session_root {
    Some(root) => CetasChildSessionStore::with_root(root + "/" + task_id)
    None => self.child_store
  }
}

///|
fn TicketRuntime::runs_for(
  self : TicketRuntime,
  task_id : String,
) -> Array[@work.WorkRun] {
  self.runs.runs_for(task_id)
}

///|
/// The run the task-level UI reads first: a live role wins, otherwise the most
/// recently added role.
fn TicketRuntime::run_for(
  self : TicketRuntime,
  task_id : String,
) -> @work.WorkRun? {
  self.runs.run_for(task_id)
}

///|
fn TicketRuntime::run_role(
  self : TicketRuntime,
  task_id : String,
  role : String,
) -> @work.WorkRun? {
  self.runs.run_role(task_id, role)
}

///|
fn TicketRuntime::all_runs(self : TicketRuntime) -> Array[@work.WorkRun] {
  self.runs.all()
}

///|
fn TicketRuntime::add_run(
  self : TicketRuntime,
  task_id : String,
  session_id : String,
  phase : String,
  role : String,
) -> @work.WorkRun {
  self.runs.add(task_id, session_id, phase, role)
}

///|
/// Append one worker progress update for a ticket, dropping the oldest once the
/// per-ticket bound is reached. Progress is host state only: it never touches
/// the Board and never parks the worker.
fn TicketRuntime::record_progress(
  self : TicketRuntime,
  task_id : String,
  kind : String,
  message : String,
) -> Unit {
  self.progress.record(task_id, kind, message)
}

///|
fn TicketRuntime::mcp_face(
  self : TicketRuntime,
  role : String,
) -> Array[&@posoco.Extension] {
  let config = match self.team_mcp.get(role) {
    Some(value) => value
    None => TeamMcp::defaults()
  }
  match self.mcp {
    Some(mcp) => {
      let exts : Array[&@posoco.Extension] = []
      match mcp.extension(role, config) {
        Some(ext) => exts.push(ext)
        None => ()
      }
      // MCP tools stay on the ordinary permission path; the Board only
      // filters which servers this role may see.
      exts
    }
    None => []
  }
}

///|
fn TicketRuntime::skill_face(
  self : TicketRuntime,
  role : String,
) -> Array[String]? {
  let config = match self.team_skills.get(role) {
    Some(value) => value
    None => TeamSkills::defaults()
  }
  if !config.enabled {
    return None
  }
  let chosen = if config.all {
    self.skills.map(skill => skill.name)
  } else {
    config.skills
  }
  let available = self.skills.map(skill => skill.name)
  let names = chosen.filter(name => available.contains(name))
  if names.is_empty() {
    None
  } else {
    Some(names)
  }
}

///|
fn TicketRuntime::team_label(self : TicketRuntime, role : String) -> String {
  match role {
    "product_owner" | "customer" => "Customer"
    "refiner" | "po" => self.team.po
    "sm" => self.team.sm
    "rd" => self.team.rd
    "set" => self.team.set
    "te" => self.team.te
    "development_group" | "worker" => "Development"
    _ => role
  }
}

///|
fn TicketRuntime::answer_question(
  self : TicketRuntime,
  question_id : String,
  response : @posoco.UiResponse,
  answered_by : String,
) -> Result[Unit, String] {
  match self.questions.answer(question_id, response, answered_by) {
    Ok((task_id, asked_by, answer)) => {
      self.record_progress(
        task_id,
        "question_answered",
        self.team_label(answered_by) +
        " answered " +
        self.team_label(asked_by) +
        ": " +
        answer,
      )
      Ok(())
    }
    Err(reason) => Err(reason)
  }
}

///|
/// Ask a Refiner child to answer one open Product Owner question. The original
/// worker stays parked; a failure leaves the question open for a human Refiner.
fn TicketRuntime::answer_as_refiner(
  self : TicketRuntime,
  question_id : String,
) -> Result[Unit, String] {
  match self.questions.questions.get(question_id) {
    Some(question) if question.status == "open" => {
      match self.questions.forward(question_id, "customer") {
        Ok(_) => ()
        Err(reason) => return Err(reason)
      }
      self.record_progress(
        question.task_id,
        "question_forwarded",
        "Customer forwarded " +
        self.team_label(question.asked_by) +
        "'s question to " +
        self.team_label("po"),
      )
      self.group.spawn_bg(async fn() {
        match self.refiner_answer(question_id) {
          Ok(_) => ()
          Err(reason) => {
            self.record_progress(
              question.task_id,
              "attention",
              "Product Owner could not answer: " + reason,
            )
            self.questions.cancel(question_id)
          }
        }
      })
      Ok(())
    }
    _ => Err("question is no longer open")
  }
}

///|
async fn TicketRuntime::refiner_answer(
  self : TicketRuntime,
  question_id : String,
) -> Result[Unit, String] {
  let question = match self.questions.questions.get(question_id) {
    Some(question) if question.status == "open" => question
    Some(_) => return Err("question is no longer open")
    None => return Err("question is no longer open")
  }
  let prompt = match question.req {
    @posoco.UiRequest::Input(prompt~, ..) => prompt
    @posoco.UiRequest::Confirm(prompt~) => prompt
    @posoco.UiRequest::Select(prompt~, ..) => prompt
  }
  let (task, _) = match self.task_snapshot(question.task_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let title = @work.task_field(task, "title")
  let description = @work.task_field(task, "description")
  let session_id = @work.work_session_id(question.task_id, "po")
  let store = self.child_store_for(question.task_id)
  let mcp_exts = self.mcp_face("po")
  let composer = CetasChildComposer::CetasChildComposer(
    parent_manager=self.manager,
    parent_mode=self.parent_mode,
    child_store=Some(store),
    approval=self.approval,
    ui=None,
    question=None,
    question_endpoint=None,
    extra_exts=mcp_exts,
    context_fs=self.ctx.fs,
    feature_fs=self.ctx.fs,
    cwd=self.ctx.cwd,
    home=self.ctx.home,
    host_group=Some(self.group),
  )
  let spec : @subagent.ChildSpec = {
    task: "Answer this question for the development group as the Product Owner.\n\nTicket: " +
    title +
    "\n\nTicket description:\n" +
    description +
    "\n\nQuestion:\n" +
    prompt +
    "\n\nGive the shortest correct answer. Do not modify files.",
    kind_name: "po-answer",
    session_id,
    resuming: true,
    tools: Some(["read", "glob", "grep"]),
    skills: self.skill_face("po"),
    mode: (self.parent_mode)(),
    system_prompt: ticket_system_prompt(
      self.ctx.cwd,
      po_system_prompt(self.team.po),
    ),
    slot: self.manager.manager_active_model_id(),
    effort: self.manager.manager_active_effort(),
    context_files: false,
    observers: [],
  }
  let agent = @subagent.ChildComposer::compose(composer, spec) catch {
    error => {
      let detail = match error {
        @subagent.Failed(detail) => detail
      }
      self.record_progress(
        question.task_id,
        "attention",
        "Product Owner could not answer: " + detail,
      )
      return Err(detail)
    }
  }
  let task_id = question.task_id
  self.group.spawn_bg(async fn() {
    let answer : Result[String, String] = Ok(
      agent.run_scoped(async fn(agent) {
        let result = agent.run_turn(
          @posoco.Message::UserMessage(content=[@posoco.Content::Text(prompt)]),
          session_id,
        )
        match result.message {
          @posoco.Message::AssistantMessage(content=blocks, ..) =>
            blocks
            .filter_map(block => {
              match block {
                @posoco.Content::Text(value) => Some(value)
                _ => None
              }
            })
            .join("\n")
          _ => ""
        }
      }),
    ) catch {
      error => Err(error.to_string())
    }
    match answer {
      Ok(text) if !text.trim().is_empty() =>
        match
          self.questions.answer(
            question_id,
            @posoco.UiResponse::Text(text),
            "po",
          ) {
          Ok((task_id, asked_by, answer)) =>
            self.record_progress(
              task_id,
              "question_answered",
              self.team_label("po") +
              " answered " +
              self.team_label(asked_by) +
              ": " +
              answer,
            )
          Err(reason) =>
            self.record_progress(
              task_id,
              "attention",
              "Product Owner answer failed: " + reason,
            )
        }
      Ok(_) =>
        self.record_progress(
          task_id, "attention", "Product Owner returned an empty answer; question is still open.",
        )
      Err(error) =>
        self.record_progress(
          task_id,
          "attention",
          "Product Owner could not answer: " + error,
        )
    }
  })
  Ok(())
}

///|
fn team_config_path(ctx : @cetas_core.HostContext) -> String {
  ctx.home +
  "/.cetas/board-team-" +
  @fs_session.project_dir_name(ctx.cwd) +
  ".json"
}

///|
async fn TicketRuntime::set_team(
  self : TicketRuntime,
  names : TeamNames,
  mcp : Map[String, TeamMcp],
  skills : Map[String, TeamSkills],
  profile : WorkProfile,
) -> Result[Json, String] noraise {
  let config : TeamConfig = { names, mcp, skills, profile, }
  self.ctx.fs.write_file_atomic(
    team_config_path(self.ctx),
    config.to_json().stringify(),
  ) catch {
    error => return Err("team settings persist failed: " + error.to_string())
  }
  self.team = names
  self.team_mcp = mcp
  self.team_skills = skills
  self.profile = profile
  Ok(self.state_json())
}

///|
/// Clear Inbox updates, all of them or one ticket's. Progress is Information
/// only, so dismissing it never changes the Board or the run.
fn TicketRuntime::dismiss_progress(
  self : TicketRuntime,
  task_id : String?,
) -> Json {
  self.progress.dismiss(task_id)
  self.state_json()
}

///|
/// Store one submitted work report for the current run. The report replaces any
/// earlier one of the same attempt; it is not written to the Board here, so the
/// Board stays the single validating writer when `finish` submits it.
fn TicketRuntime::record_work_report(
  self : TicketRuntime,
  task_id : String,
  role : String,
  report : Json,
) -> Result[Unit, String] {
  let run = match self.run_role(task_id, role) {
    Some(run) => run
    None => return Err("ticket run is no longer active")
  }
  match @work.validate_work_report(report) {
    Ok(_) => ()
    Err(reason) => return Err(reason)
  }
  run.report = Some(report)
  Ok(())
}

///|
priv struct TicketReportAdapter {
  runtime : TicketRuntime
  task_id : String
  role : String
}

///|
impl TicketReportEndpoint for TicketReportAdapter with fn report_progress(
  self,
  kind,
  message,
) -> Unit {
  self.runtime.record_progress(self.task_id, kind, message)
}

///|
impl TicketReportEndpoint for TicketReportAdapter with fn submit_work_report(
  self,
  report,
) -> Result[Unit, String] {
  self.runtime.record_work_report(self.task_id, self.role, report)
}

///|
async fn TicketRuntime::snapshot_sync(
  self : TicketRuntime,
) -> Result[@board_protocol.BoardSnapshot, String] {
  let encoded = match self.board.wire_snapshot() {
    Ok(encoded) => encoded
    Err(error) => return Err(error.code())
  }
  match @board_protocol.decode_server_frame(encoded) {
    Ok(@board_protocol.Snapshot(snapshot)) => Ok(snapshot)
    _ => Err("board snapshot frame was invalid")
  }
}

///|
/// Rehydrate interrupted work once from the durable child sessions. The Board
/// stage is the authority; a suspended/running task with a recorded work
/// session is shown as interrupted, never silently resumed or relabelled.
async fn TicketRuntime::reconcile_interrupted(self : TicketRuntime) -> Unit {
  if self.reconciled {
    return
  }
  self.reconciled = true
  let snapshot = match self.snapshot_sync() {
    Ok(snapshot) => snapshot
    Err(_) => return
  }
  let state = match @work.BoardState::tasks_from_snapshot(snapshot) {
    Ok(state) => state
    Err(_) => return
  }
  for task in state.tasks {
    if self.run_for(@work.task_field(task, "id")) is Some(_) {
      continue
    }
    let stage = @work.task_field(task, "stage")
    if stage != "running" && stage != "suspended" {
      continue
    }
    let task_id = @work.task_field(task, "id")
    if task_id == "" {
      continue
    }
    let session_id = @work.work_session_id(task_id, "rd")
    let store = self.child_store_for(task_id)
    let session = store.load(session_id) catch { _ => continue }
    if session.messages.is_empty() {
      continue
    }
    let run = self.add_run(task_id, session_id, "work", "rd")
    run.status = "interrupted"
    run.error = Some(
      "Host restarted before this run finished. Resume continues the durable session.",
    )
    run.activities.push({
      at_ms: @async.now(),
      kind: "recover",
      text: "Durable session found; run marked interrupted",
    })
  }
}

///|
/// The host projection of every ticket run, question and worker progress line.
/// `progress` is the bounded per-ticket log (`task_id`, `kind`, `message`,
/// `at_ms`), so a drawer can show what a worker said while it worked without
/// the host keeping an unbounded transcript.
fn TicketRuntime::state_json(self : TicketRuntime) -> Json {
  let runs : Array[Json] = self.all_runs().map(run => run.to_json())
  let progress_items : Array[Json] = self.progress
    .all()
    .map(update => update.to_json())
  let catalog = self.manager.manager_ticket_model_catalog_json()
  let (_, catalog_models) = ticket_catalog_entries(catalog)
  let manager_kind = match catalog {
    Object(fields) =>
      match fields.get("kind") {
        Some(String(kind)) => kind
        _ => "unknown"
      }
    _ => "unknown"
  }
  let running = self.runs.count_running()
  let mut waiting_input = 0
  for question in self.questions.questions.values() {
    if question.status == "open" {
      waiting_input = waiting_input + 1
    }
  }
  let attention = self.progress.attention_tasks()
  let presence = @board_presence.BoardPresence::project(
    running~,
    waiting_input~,
    attention~,
  )
  Json::object({
    "project": Json::string(project_name(self.ctx.cwd)),
    "team": self.team.to_json(),
    "team_mcp": TeamMcp::to_json_map(self.team_mcp),
    "team_skills": TeamSkills::to_json_map(self.team_skills),
    "skills": Json::array(self.skills.map(BoardSkill::to_json)),
    "mcp_servers": match self.mcp {
      Some(mcp) => mcp.catalog_json()
      None => Json::object({ "servers": Json::array([]) })
    },
    "work_profile": self.profile.to_json(),
    "presence": presence.to_json(),
    "questions": self.questions.json(),
    "runs": Json::array(runs),
    "progress": Json::array(progress_items),
    "live": Json::object({
      "manager": Json::string(manager_kind),
      "active_model": Json::string(self.manager.manager_active_model_id()),
      "active_effort": match self.manager.manager_active_effort() {
        Some(effort) => Json::string(effort)
        None => Json::null()
      },
      "model_count": Json::number(catalog_models.length().to_double()),
      "quota": Json::null(),
      "status": self.manager.manager_status_json(),
    }),
    "model_selection": catalog,
  })
}

///|
async fn TicketRuntime::snapshot(
  self : TicketRuntime,
) -> Result[@board_protocol.BoardSnapshot, String] {
  self.snapshot_sync()
}

///|
async fn TicketRuntime::assign_role(
  self : TicketRuntime,
  task_id : String,
  role : String,
  member_id : String,
) -> Result[Unit, String] {
  let snapshot = match self.snapshot() {
    Ok(snapshot) => snapshot
    Err(error) => return Err(error)
  }
  self.counter = self.counter + 1
  let command : @board_protocol.BoardClientCommand = {
    command_id: "ticket-assign-" + self.counter.to_string(),
    name: "board.task.assign_role",
    expected_revision: snapshot.board_revision,
    args: {
      "id": Json::string(task_id),
      "role": Json::string(role),
      "member_id": Json::string(member_id),
    },
  }
  let encoded = match
    self.board.wire_command(
      @board_protocol.encode_client_frame(@board_protocol.Command(command)),
    ) {
    Ok(encoded) => encoded
    Err(error) => return Err(error.code())
  }
  match @board_protocol.decode_server_frame(encoded) {
    Ok(@board_protocol.CommandResult(result)) =>
      if result.accepted {
        Ok(())
      } else {
        Err(
          match result.error {
            Some(error) => error
            None => "board command rejected"
          },
        )
      }
    _ => Err("board command result was invalid")
  }
}

///|

///|
async fn TicketRuntime::set_required_roles(
  self : TicketRuntime,
  task_id : String,
  roles : Array[String],
) -> Result[Unit, String] {
  let snapshot = match self.snapshot() {
    Ok(snapshot) => snapshot
    Err(error) => return Err(error)
  }
  self.counter = self.counter + 1
  let command : @board_protocol.BoardClientCommand = {
    command_id: "ticket-roles-" + self.counter.to_string(),
    name: "board.task.set_required_roles",
    expected_revision: snapshot.board_revision,
    args: {
      "id": Json::string(task_id),
      "roles": Json::array(roles.map(Json::string)),
    },
  }
  let encoded = match
    self.board.wire_command(
      @board_protocol.encode_client_frame(@board_protocol.Command(command)),
    ) {
    Ok(encoded) => encoded
    Err(error) => return Err(error.code())
  }
  match @board_protocol.decode_server_frame(encoded) {
    Ok(@board_protocol.CommandResult(result)) =>
      if result.accepted {
        Ok(())
      } else {
        Err(
          match result.error {
            Some(error) => error
            None => "board command rejected"
          },
        )
      }
    _ => Err("board command result was invalid")
  }
}

///|
async fn TicketRuntime::assign_development_team(
  self : TicketRuntime,
  task_id : String,
) -> Result[Unit, String] {
  for role in ["rd", "set", "te"] {
    match self.assign_role(task_id, role, role) {
      Ok(_) => ()
      Err(error) => return Err("could not assign " + role + ": " + error)
    }
  }
  Ok(())
}

///|
async fn TicketRuntime::move_task(
  self : TicketRuntime,
  task_id : String,
  to : String,
) -> Result[Unit, String] {
  let snapshot = match self.snapshot() {
    Ok(snapshot) => snapshot
    Err(error) => return Err(error)
  }
  let command : @board_protocol.BoardClientCommand = {
    command_id: "ticket-move-" + self.counter.to_string(),
    name: "board.task.move",
    expected_revision: snapshot.board_revision,
    args: { "id": Json::string(task_id), "to": Json::string(to) },
  }
  let encoded = match
    self.board.wire_command(
      @board_protocol.encode_client_frame(@board_protocol.Command(command)),
    ) {
    Ok(encoded) => encoded
    Err(error) => return Err(error.code())
  }
  match @board_protocol.decode_server_frame(encoded) {
    Ok(@board_protocol.CommandResult(result)) =>
      if result.accepted {
        Ok(())
      } else {
        Err(
          match result.error {
            Some(error) => error
            None => "board command rejected"
          },
        )
      }
    _ => Err("board command result was invalid")
  }
}

///|
async fn TicketRuntime::apply_task_model(
  self : TicketRuntime,
  task_id : String,
  model : Json,
) -> Result[Unit, String] {
  let snapshot = match self.snapshot() {
    Ok(snapshot) => snapshot
    Err(error) => return Err(error)
  }
  self.board_command(
    "board.task.set_model",
    { "id": Json::string(task_id), "model": model },
    snapshot.board_revision,
  )
}

///|
async fn TicketRuntime::set_task_model(
  self : TicketRuntime,
  task_id : String,
  model : @work.ModelPin,
) -> Result[Unit, String] {
  self.apply_task_model(task_id, @work.model_pin_json(Some(model)))
}

///|
/// The catalog entry a ticket pin is validated against: the selectable flag
/// and the models the manager currently advertises. A malformed projection
/// reads as "nothing selectable" instead of vouching for a pin.
fn ticket_catalog_entries(catalog : Json) -> (Bool, Array[Json]) {
  match catalog {
    Object(fields) => {
      let selectable = fields.get("selectable") is Some(True)
      let models = match fields.get("models") {
        Some(Array(models)) => models
        _ => []
      }
      (selectable, models)
    }
    _ => (false, [])
  }
}

///|
fn ticket_catalog_efforts(
  models : Array[Json],
  slot : String,
) -> Array[String]? {
  for item in models {
    guard item is Object(entry) else { continue }
    guard entry.get("id") is Some(String(id)) && id == slot else { continue }
    let efforts : Array[String] = []
    match entry.get("efforts") {
      Some(Array(values)) =>
        for value in values {
          match value {
            String(effort) => efforts.push(effort)
            _ => ()
          }
        }
      _ => ()
    }
    return Some(efforts)
  }
  None
}

///|
/// Validate one ticket model pin against the current manager catalog.
///
/// The catalog is the only authority for a pin: the manager kind must be
/// selectable, the slot must be one the catalog advertises right now, and an
/// effort must be one that slot advertises. `None` means inherit and is
/// always accepted for a selectable manager — inheritance is resolved when
/// the child is composed, so it is never rewritten into a pin here. Nothing
/// falls back silently: an absent slot or an unadvertised effort is a
/// readable error, so a stale Board draft cannot pin a model the router
/// cannot run.
fn TicketRuntime::ticket_model_arg(
  self : TicketRuntime,
  model : @work.ModelPin?,
) -> Result[Json, String] {
  let catalog = self.manager.manager_ticket_model_catalog_json()
  let (selectable, models) = ticket_catalog_entries(catalog)
  if !selectable {
    let kind = match catalog {
      Object(fields) =>
        match fields.get("kind") {
          Some(String(kind)) => kind
          _ => "unknown"
        }
      _ => "unknown"
    }
    return Err(
      "ticket model selection is unavailable: the '" +
      kind +
      "' model manager does not expose selectable slots",
    )
  }
  let model = match model {
    None => return Ok(Json::null())
    Some(model) => model
  }
  let slot = match model.slot.trim() {
    "" => return Err("ticket model slot must be a non-empty string")
    _ => model.slot
  }
  guard ticket_catalog_efforts(models, slot) is Some(efforts) else {
    return Err("model slot '" + slot + "' is not in the current model catalog")
  }
  match model.effort {
    Some(effort) =>
      if !efforts.contains(effort) {
        return Err(
          "model slot '" + slot + "' does not advertise effort '" + effort + "'",
        )
      }
    None => ()
  }
  Ok(@work.model_pin_json(Some(model)))
}

///|
/// Pin, or explicitly clear, the model one Board ticket runs with.
///
/// The ticket runtime owns the catalog gate; the Board owns the durable
/// field. A pin is validated first, then written through
/// `board.task.set_model` at the current Board revision, and the updated
/// ticket state JSON is returned so the caller never re-reads a stale
/// projection.
async fn TicketRuntime::set_model(
  self : TicketRuntime,
  task_id : String,
  model : @work.ModelPin?,
) -> Result[Json, String] {
  let encoded = match self.ticket_model_arg(model) {
    Ok(encoded) => encoded
    Err(reason) => return Err(reason)
  }
  match self.apply_task_model(task_id, encoded) {
    Ok(_) => Ok(self.state_json())
    Err(error) => Err(error)
  }
}

///|
async fn TicketRuntime::board_command(
  self : TicketRuntime,
  name : String,
  args : Json,
  expected_revision : Int64,
) -> Result[Unit, String] {
  let command : @board_protocol.BoardClientCommand = {
    command_id: "ticket-" + name + "-" + self.counter.to_string(),
    name,
    expected_revision,
    args,
  }
  let encoded = match
    self.board.wire_command(
      @board_protocol.encode_client_frame(@board_protocol.Command(command)),
    ) {
    Ok(encoded) => encoded
    Err(error) => return Err(error.code())
  }
  match @board_protocol.decode_server_frame(encoded) {
    Ok(@board_protocol.CommandResult(result)) =>
      if result.accepted {
        Ok(())
      } else {
        Err(
          match result.error {
            Some(error) => error
            None => "board command rejected"
          },
        )
      }
    _ => Err("board command result was invalid")
  }
}

///|
async fn TicketRuntime::create_task(
  self : TicketRuntime,
  task_id : String,
  title : String,
  user_story : String,
  description : String,
  implementation_suggestions : String,
  priority : String,
  definition_of_done : Array[String],
) -> Result[Unit, String] {
  let snapshot = match self.snapshot() {
    Ok(snapshot) => snapshot
    Err(error) => return Err(error)
  }
  self.board_command(
    "board.task.create",
    {
      "id": Json::string(task_id),
      "title": Json::string(title),
      "description": Json::string(description),
      "priority": Json::string(priority),
      "definition_of_done": Json::array(definition_of_done.map(Json::string)),
      "dependencies": Json::array([]),
      "user_story": Json::string(user_story),
      "implementation_suggestions": Json::string(implementation_suggestions),
    },
    snapshot.board_revision,
  )
}

///|
async fn TicketRuntime::delete_task(
  self : TicketRuntime,
  task_id : String,
) -> Result[Unit, String] {
  let snapshot = match self.snapshot() {
    Ok(snapshot) => snapshot
    Err(error) => return Err(error)
  }
  self.board_command(
    "board.task.delete",
    { "id": Json::string(task_id) },
    snapshot.board_revision,
  )
}

///|
async fn TicketRuntime::task_has_dependents(
  self : TicketRuntime,
  task_id : String,
) -> Result[Bool, String] {
  let snapshot = match self.snapshot() {
    Ok(snapshot) => snapshot
    Err(error) => return Err(error)
  }
  let state = match @work.BoardState::tasks_from_snapshot(snapshot) {
    Ok(state) => state
    Err(error) => return Err(error)
  }
  Ok(state.has_dependents(task_id))
}

///|
/// Replace one ticket's review report at the current Board revision. The Board
/// owns the report; this runtime only supplies it, so nothing here re-reads a
/// stale projection. `Json::null()` is the Board's explicit clear, not a
/// fallback for a rejected report.
async fn TicketRuntime::set_review_report(
  self : TicketRuntime,
  task_id : String,
  review : Json,
) -> Result[Unit, String] {
  let snapshot = match self.snapshot() {
    Ok(snapshot) => snapshot
    Err(error) => return Err(error)
  }
  self.board_command(
    "board.task.set_review_report",
    { "id": Json::string(task_id), "review": review },
    snapshot.board_revision,
  )
}

///|
/// Record a finished run without moving the Board. A worker failure — including
/// a paused network stream — must stay in its current lane with a visible
/// error so the durable session can be resumed; moving it to Paused would
/// discard that recovery path. The Board stage moves only when a command
/// explicitly asks for it.
fn TicketRuntime::park_run(
  self : TicketRuntime,
  task_id : String,
  role : String,
  status : String,
  error : String,
) -> Unit {
  self.runs.park(task_id, role, status, error)
}

///|
fn TicketRuntime::team_complete(
  self : TicketRuntime,
  task_id : String,
  roles : Array[String],
) -> Bool {
  let gates = roles.filter(role => role == "rd" || role == "set")
  self.runs.roles_completed(task_id, gates)
}

///|
async fn TicketRuntime::finish_work(
  self : TicketRuntime,
  task_id : String,
  role : String,
  outcome : Result[String, String],
) -> Unit {
  let run = match self.run_role(task_id, role) {
    Some(run) => run
    None => return
  }
  match outcome {
    Ok(result) => {
      run.result = Some(result)
      if role == "te" {
        let report = match run.report {
          Some(report) => report
          None => @work.minimal_review_report(result)
        }
        match self.set_review_report(task_id, report) {
          Ok(_) => ()
          Err(error) => {
            self.park_run(
              task_id,
              role,
              "failed",
              "review report was not recorded: " + error,
            )
            return
          }
        }
        match self.move_task(task_id, "review") {
          Ok(_) => {
            run.status = "review"
            run.error = None
          }
          Err(error) =>
            self.park_run(
              task_id,
              role,
              "failed",
              "review move was not accepted: " + error,
            )
        }
      } else {
        run.status = "completed"
        run.error = None
        let task = match self.task_snapshot(task_id) {
          Ok((task, _)) => task
          Err(error) => {
            self.park_run(task_id, role, "failed", error)
            return
          }
        }
        let roles = @work.task_required_roles(task)
        if self.team_complete(task_id, roles) {
          if roles.contains("te") {
            match self.move_task(task_id, "verification") {
              Ok(_) =>
                match self.start_role(task_id, task, "te", false) {
                  Ok(_) => ()
                  Err(error) => self.park_run(task_id, "te", "failed", error)
                }
              Err(error) =>
                self.park_run(
                  task_id,
                  role,
                  "failed",
                  "verification move failed: " + error,
                )
            }
          } else {
            let report = match run.report {
              Some(report) => report
              None => @work.minimal_review_report(result)
            }
            match self.set_review_report(task_id, report) {
              Ok(_) => ()
              Err(error) => {
                self.park_run(
                  task_id,
                  role,
                  "failed",
                  "review report was not recorded: " + error,
                )
                return
              }
            }
            match self.move_task(task_id, "review") {
              Ok(_) => {
                run.status = "review"
                run.error = None
              }
              Err(error) =>
                self.park_run(
                  task_id,
                  role,
                  "failed",
                  "review move was not accepted: " + error,
                )
            }
          }
        }
      }
    }
    Err(error) => self.park_run(task_id, role, "failed", error)
  }
}

///|
async fn TicketRuntime::task_snapshot(
  self : TicketRuntime,
  task_id : String,
) -> Result[(Json, Int64), String] {
  let snapshot = match self.snapshot() {
    Ok(snapshot) => snapshot
    Err(error) => return Err(error)
  }
  let state = match @work.BoardState::tasks_from_snapshot(snapshot) {
    Ok(state) => state
    Err(error) => return Err(error)
  }
  match state.task(task_id) {
    Some(task) => Ok((task, state.revision))
    None => Err("ticket was not found")
  }
}

///|
async fn TicketRuntime::update_task(
  self : TicketRuntime,
  task_id : String,
  title : String?,
  user_story : String?,
  description : String?,
  implementation_suggestions : String?,
  priority : String?,
  definition_of_done : Array[String]?,
) -> Result[Unit, String] {
  let revision = match self.task_snapshot(task_id) {
    Ok((_, revision)) => revision
    Err(error) => return Err(error)
  }
  let fields : Map[String, Json] = Map::from_array([
    ("id", Json::string(task_id)),
  ])
  match title {
    Some(value) => fields["title"] = Json::string(value)
    None => ()
  }
  match user_story {
    Some(value) => fields["user_story"] = Json::string(value)
    None => ()
  }
  match description {
    Some(value) => fields["description"] = Json::string(value)
    None => ()
  }
  match implementation_suggestions {
    Some(value) => fields["implementation_suggestions"] = Json::string(value)
    None => ()
  }
  match priority {
    Some(value) => fields["priority"] = Json::string(value)
    None => ()
  }
  match definition_of_done {
    Some(values) =>
      fields["definition_of_done"] = Json::array(values.map(Json::string))
    None => ()
  }
  let command : @board_protocol.BoardClientCommand = {
    command_id: "ticket-update-" + self.counter.to_string(),
    name: "board.task.update",
    expected_revision: revision,
    args: Json::object(fields),
  }
  let encoded = match
    self.board.wire_command(
      @board_protocol.encode_client_frame(@board_protocol.Command(command)),
    ) {
    Ok(encoded) => encoded
    Err(error) => return Err(error.code())
  }
  match @board_protocol.decode_server_frame(encoded) {
    Ok(@board_protocol.CommandResult(result)) =>
      if result.accepted {
        Ok(())
      } else {
        Err(
          match result.error {
            Some(error) => error
            None => "board update rejected"
          },
        )
      }
    _ => Err("board update result was invalid")
  }
}

///|
fn ticket_language_contract() -> String {
  "Language override for this Board ticket:\n" +
  "- The host prompt is English for stability. The user's language is the language of the ticket title/description and the most recent Inbox answer.\n" +
  "- Ask questions and write descriptions, definition-of-done items, summaries, split titles, results, and explanations in that language.\n" +
  "- If the user switches language, follow the latest user-authored text.\n" +
  "- Keep code, identifiers, file paths, commands, and quoted errors verbatim. JSON keys stay English."
}

///|
fn ticket_system_prompt(cwd : String, role : String) -> String {
  @cetas_core.cetas_system_prompt(cwd~) +
  "\n\n" +
  role +
  "\n\n" +
  ticket_language_contract()
}

///|
async fn TicketRuntime::rollback_split(
  self : TicketRuntime,
  created : Array[String],
) -> String {
  let failures : Array[String] = []
  let mut index = created.length()
  while index > 0 {
    index = index - 1
    match self.delete_task(created[index]) {
      Ok(_) => ()
      Err(error) => failures.push(created[index] + ": " + error)
    }
  }
  if failures.is_empty() {
    ""
  } else {
    "; rollback failed for " + failures.join("; ")
  }
}

///|
async fn TicketRuntime::split_ticket(
  self : TicketRuntime,
  source_id : String,
  children : Array[@work.ShapeChild],
) -> Result[String, String] {
  match self.task_has_dependents(source_id) {
    Ok(true) =>
      return Err(
        "ticket is still a dependency of another task; remove that edge before splitting",
      )
    Ok(false) => ()
    Err(error) => return Err(error)
  }
  let (source, _) = match self.task_snapshot(source_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let source_model = @work.task_model(source)
  let created : Array[String] = []
  let stamp = @async.now()
  for index, child in children {
    let task_id = "split-" +
      source_id +
      "-" +
      stamp.to_string() +
      "-" +
      index.to_string()
    match
      self.create_task(
        task_id,
        child.title,
        child.user_story,
        child.description,
        child.implementation_suggestions,
        child.priority,
        child.definition_of_done,
      ) {
      Ok(_) => ()
      Err(error) => {
        let rollback = self.rollback_split(created)
        return Err("could not create split ticket: " + error + rollback)
      }
    }
    created.push(task_id)
    match source_model {
      Some(model) =>
        match self.set_task_model(task_id, model) {
          Ok(_) => ()
          Err(error) => {
            let rollback = self.rollback_split(created)
            return Err(
              "could not pin the split ticket model: " + error + rollback,
            )
          }
        }
      None => ()
    }
    match self.assign_development_team(task_id) {
      Ok(_) => ()
      Err(error) => {
        let rollback = self.rollback_split(created)
        return Err("could not assign split ticket team: " + error + rollback)
      }
    }
    match self.set_required_roles(task_id, child.required_roles) {
      Ok(_) => ()
      Err(error) => {
        let rollback = self.rollback_split(created)
        return Err("could not set split ticket role plan: " + error + rollback)
      }
    }
    match self.move_task(task_id, "refining") {
      Ok(_) => ()
      Err(error) => {
        let rollback = self.rollback_split(created)
        return Err(
          "could not move split ticket to Shaping: " + error + rollback,
        )
      }
    }
    match self.move_task(task_id, "ready") {
      Ok(_) => ()
      Err(error) => {
        let rollback = self.rollback_split(created)
        return Err("could not move split ticket to Ready: " + error + rollback)
      }
    }
  }
  match self.move_task(source_id, "cancelled") {
    Ok(_) => {
      let titles = children.map(child => child.title).join(", ")
      Ok("Split into \{children.length()} tickets: " + titles)
    }
    Err(error) => {
      let rollback = self.rollback_split(created)
      Err(
        "split tickets were created but the source could not be cancelled: " +
        error +
        rollback,
      )
    }
  }
}

///|
async fn TicketRuntime::finish_shape(
  self : TicketRuntime,
  task_id : String,
  outcome : Result[String, String],
) -> Unit {
  let run = self.run_for(task_id)
  let result = match outcome {
    Ok(text) => text
    Err(error) => {
      match run {
        Some(run) => {
          run.status = "failed"
          run.error = Some(error)
        }
        None => ()
      }
      return
    }
  }
  let parsed = match @work.extract_json_object(result) {
    Some(Json::Object(fields)) => fields
    _ => {
      match run {
        Some(run) => {
          run.status = "failed"
          run.error = Some("shaping output was not a JSON object")
        }
        None => ()
      }
      return
    }
  }
  let summary = match parsed.get("summary") {
    Some(String(value)) => value
    _ => "Ticket shaped"
  }
  let (source, _) = match self.task_snapshot(task_id) {
    Ok(value) => value
    Err(error) => {
      match run {
        Some(run) => {
          run.status = "failed"
          run.error = Some(error)
        }
        None => ()
      }
      return
    }
  }
  let fallback_priority = match @work.task_field(source, "priority") {
    "" => "normal"
    value => value
  }
  if parsed.get("tasks") is Some(tasks) {
    let children = match
      @work.parse_shape_children(Some(tasks), fallback_priority) {
      Ok(children) => children
      Err(error) => {
        match run {
          Some(run) => {
            run.status = "failed"
            run.error = Some(error)
          }
          None => ()
        }
        return
      }
    }
    match self.split_ticket(task_id, children) {
      Ok(text) =>
        match run {
          Some(run) => {
            run.status = "shaped"
            run.result = Some(text)
          }
          None => ()
        }
      Err(error) =>
        match run {
          Some(run) => {
            run.status = "failed"
            run.error = Some(error)
          }
          None => ()
        }
    }
    return
  }
  let child = match
    @work.parse_shape_story(
      parsed,
      fallback_priority,
      title_fallback=@work.task_field(source, "title"),
    ) {
    Ok(child) => child
    Err(error) => {
      match run {
        Some(run) => {
          run.status = "failed"
          run.error = Some(error)
        }
        None => ()
      }
      return
    }
  }
  match
    self.update_task(
      task_id,
      Some(child.title),
      Some(child.user_story),
      Some(child.description),
      Some(child.implementation_suggestions),
      Some(child.priority),
      Some(child.definition_of_done),
    ) {
    Ok(_) => ()
    Err(error) => {
      match run {
        Some(run) => {
          run.status = "failed"
          run.error = Some(error)
        }
        None => ()
      }
      return
    }
  }
  match self.assign_development_team(task_id) {
    Ok(_) => ()
    Err(error) => {
      match run {
        Some(run) => {
          run.status = "failed"
          run.error = Some(error)
        }
        None => ()
      }
      return
    }
  }
  match self.set_required_roles(task_id, child.required_roles) {
    Ok(_) => ()
    Err(error) => {
      match run {
        Some(run) => {
          run.status = "failed"
          run.error = Some(error)
        }
        None => ()
      }
      return
    }
  }
  match self.move_task(task_id, "ready") {
    Ok(_) =>
      match run {
        Some(run) => {
          run.status = "shaped"
          run.result = Some(summary)
        }
        None => ()
      }
    Err(error) =>
      match run {
        Some(run) => {
          run.status = "failed"
          run.error = Some(error)
        }
        None => ()
      }
  }
}

///|
async fn TicketRuntime::shape(
  self : TicketRuntime,
  task_id : String,
) -> Result[Unit, String] {
  if self.run_for(task_id) is Some(run) && run.status == "running" {
    return Err("ticket is already running")
  }
  let (task, _) = match self.task_snapshot(task_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let stage = @work.task_field(task, "stage")
  if stage != "created" && stage != "refining" && stage != "ready" {
    return Err(
      "ticket must be Backlog, Shaping, or Ready before it can be shaped",
    )
  }
  if stage == "created" || stage == "ready" {
    match self.move_task(task_id, "refining") {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  let title = @work.task_field(task, "title")
  let description = @work.task_field(task, "description")
  let (slot, effort) = match @work.task_model(task) {
    Some(model) => (model.slot, model.effort)
    None =>
      (
        self.manager.manager_active_model_id(),
        self.manager.manager_active_effort(),
      )
  }
  self.counter = self.counter + 1
  let session_id = @work.work_session_id(task_id, "po")
  let store = self.child_store_for(task_id)
  store.clear_session(session_id) catch {
    error =>
      return Err(
        "could not clear the previous shaping session: " + error.to_string(),
      )
  }
  let _run = self.add_run(task_id, session_id, "shape", "po")
  let endpoint : @work.BoardQuestionEndpoint = {
    questions: self.questions,
    task_id,
    asked_by: "po",
    audience: "customer",
    on_open: None,
    auto_po: None,
  }
  let observer = @work.TicketActivityObserver::{
    run: self.run_for(task_id).unwrap(),
  }
  observer.run.activity("start", "Started")
  let mcp_exts = self.mcp_face("po")
  let composer = CetasChildComposer::CetasChildComposer(
    parent_manager=self.manager,
    parent_mode=self.parent_mode,
    child_store=Some(store),
    approval=self.approval,
    ui=None,
    question=None,
    question_endpoint=Some(endpoint as &@askquestion.QuestionEndpoint),
    extra_exts=mcp_exts,
    context_fs=self.ctx.fs,
    feature_fs=self.ctx.fs,
    cwd=self.ctx.cwd,
    home=self.ctx.home,
    host_group=Some(self.group),
  )
  let prompt = "Refine this Board backlog item into an implementation-ready user story. You are the Product Owner for this ticket. The person in Cetas is the Customer.\n\n" +
    "Title: " +
    title +
    "\n\nCurrent description:\n" +
    description +
    "\n\nInspect relevant workspace files when useful. Ask the Product Owner with ask_question_child about genuinely ambiguous business intent. Do not modify files and do not mutate the Board.\n\n" +
    "Set required_roles to [\"rd\"] for research, audit, spike, analysis or report tickets; use [\"rd\",\"set\",\"te\"] only when implementation, independent verification and final verification all add value. Rewrite the request as a standard user story in exactly three lines: \"As a <role>\\nI want <capability>\\nSo that <benefit>\". The user_story JSON value must contain two newline escapes (\\n), not a comma-separated sentence. Add a detailed description, concrete implementation suggestions, and observable acceptance criteria. Set a P0-P3 priority (P0 first). If the request is actually several independent user stories, split it into 2-8 complete stories; do not split a single story just to make it smaller. Each story must be independently implementable and testable.\n\n" +
    "Return only one JSON object. One story:\n" +
    "{\"summary\":\"one sentence\",\"title\":\"short title\",\"user_story\":\"As a ...\\nI want ...\\nSo that ...\",\"description\":\"detailed scope and constraints\",\"implementation_suggestions\":\"starting points, not a mandate\",\"definition_of_done\":[\"observable criterion\"],\"priority\":\"p1\",\"required_roles\":[\"rd\",\"set\",\"te\"]}\n" +
    "Split:\n" +
    "{\"summary\":\"why these are independent stories\",\"tasks\":[{\"title\":\"short title\",\"user_story\":\"As a ...\\nI want ...\\nSo that ...\",\"description\":\"scope\",\"implementation_suggestions\":\"starting points\",\"definition_of_done\":[\"observable criterion\"],\"priority\":\"p1\",\"required_roles\":[\"rd\",\"set\",\"te\"]}]}\n" +
    "Every field is required. Use the language of the ticket title/description for every value; JSON keys stay English. Do not wrap it in Markdown."
  let spec : @subagent.ChildSpec = {
    task: prompt,
    kind_name: "shape",
    session_id,
    resuming: false,
    tools: Some(["read", "glob", "grep", "astgrep", "ask_question"]),
    skills: self.skill_face("po"),
    mode: (self.parent_mode)(),
    system_prompt: ticket_system_prompt(
      self.ctx.cwd,
      po_system_prompt(self.team.po),
    ),
    slot,
    effort,
    context_files: false,
    observers: [observer as &@posoco.Observer],
  }
  let agent = @subagent.ChildComposer::compose(composer, spec) catch {
    error => {
      let detail = match error {
        @subagent.Failed(detail) => detail
      }
      match self.run_for(task_id) {
        Some(run) => {
          run.status = "failed"
          run.error = Some(detail)
        }
        None => ()
      }
      return Err("shaping composition failed: " + detail)
    }
  }
  self.group.spawn_bg(async fn() {
    let outcome : Result[String, String] = Ok(
      agent.run_scoped(async fn(agent) {
        agent.set_active_session(Some(session_id))
        let result = agent.run_turn(
          @posoco.Message::UserMessage(content=[@posoco.Content::Text(prompt)]),
          session_id,
        )
        match result.message {
          @posoco.Message::AssistantMessage(content=blocks, ..) =>
            blocks
            .filter_map(block => {
              match block {
                @posoco.Content::Text(value) => Some(value)
                _ => None
              }
            })
            .join("\n")
          _ => ""
        }
      }),
    ) catch {
      error => Err(error.to_string())
    }
    self.finish_shape(task_id, outcome)
  })
  Ok(())
}

///|
fn worker_tools(role : String) -> Array[String] {
  if role == "te" {
    ["read", "glob", "grep", "astgrep", "ask_question"]
  } else {
    [
      "read",
      "glob",
      "grep",
      "astgrep",
      "write",
      "edit",
      if shell_platform_is_windows() {
        "ps1"
      } else {
        "bash"
      },
      "ask_question",
    ]
  }
}

///|
fn worker_prompt(
  task : Json,
  role : String,
  resuming : Bool,
  prior : Array[@work.WorkRun],
) -> String {
  let title = @work.task_field(task, "title")
  let description = @work.task_field(task, "description")
  let done = @work.task_definition_of_done(task)
  let feedback = match @work.task_review_feedback(task) {
    Some(text) =>
      "\n\nReviewer feedback — this attempt must address it:\n" + text
    None => ""
  }
  let evidence = if role == "te" {
    let lines : Array[String] = []
    for run in prior {
      if run.role != "te" {
        lines.push(
          run.role +
          " (" +
          run.status +
          "): " +
          (match run.result {
            Some(result) => result
            None => "(no result)"
          }),
        )
      }
    }
    if lines.is_empty() {
      ""
    } else {
      "\n\nDevelopment handoff:\n" + lines.join("\n")
    }
  } else {
    ""
  }
  let opening = if resuming {
    "Resume this Board ticket after the host restarted. Continue from the recorded session; do not repeat work that is already complete.\n\n"
  } else {
    match role {
      "rd" => "Work on this Board ticket as RD. Produce the product change.\n\n"
      "set" =>
        "Work on this Board ticket as SET. Build independent verification against the user story.\n\n"
      _ =>
        "Work on this Board ticket as TE. Verify RD using SET's independent evidence.\n\n"
    }
  }
  opening +
  "Title: " +
  title +
  "\n\nDescription:\n" +
  description +
  "\n\nDefinition of done:\n" +
  (if done.is_empty() {
    "(none recorded)"
  } else {
    done.map(item => "- " + item).join("\n")
  }) +
  feedback +
  evidence +
  "\n\nReporting contract:\n" +
  "- Call report_progress when you start, after each significant milestone, when you investigate a problem, and before your final answer.\n" +
  "- Call submit_work_report with outcome, summary, changes, verification, risks, notes, open questions and artifacts before your final answer.\n" +
  "- Use ask_question_child with audience=\"po\" for requirement/design questions and audience=\"customer\" for business trade-offs; never use report_progress for questions.\n\n" +
  "Do not mutate the Board. End with a concise result and the evidence you verified."
}

///|
async fn TicketRuntime::start_role(
  self : TicketRuntime,
  task_id : String,
  task : Json,
  role : String,
  resuming : Bool,
) -> Result[Unit, String] {
  let session_id = @work.work_session_id(task_id, role)
  let store = self.child_store_for(task_id)
  if !resuming {
    store.clear_session(session_id) catch {
      error =>
        return Err(
          "could not clear the " + role + " session: " + error.to_string(),
        )
    }
  }
  let (slot, effort) = match @work.task_model(task) {
    Some(model) => (model.slot, model.effort)
    None =>
      (
        self.manager.manager_active_model_id(),
        self.manager.manager_active_effort(),
      )
  }
  let run = self.add_run(task_id, session_id, "work", role)
  let endpoint : @work.BoardQuestionEndpoint = {
    questions: self.questions,
    task_id,
    asked_by: role,
    audience: "po",
    on_open: Some(fn(id, task_id, asked_by, audience, prompt) {
      let _ = id
      ignore(audience)
      self.record_progress(
        task_id,
        "question_asked",
        self.team_label(asked_by) +
        " asked " +
        self.team_label("po") +
        ": " +
        prompt,
      )
    }),
    auto_po: Some(fn(id) {
      self.group.spawn_bg(async fn() {
        match self.refiner_answer(id) {
          Ok(_) => ()
          Err(reason) => {
            match self.questions.questions.get(id) {
              Some(question) =>
                self.record_progress(
                  question.task_id,
                  "attention",
                  "Product Owner could not answer: " + reason,
                )
              None => ()
            }
            self.questions.cancel(id)
          }
        }
      })
    }),
  }
  let reporting : TicketReportAdapter = { runtime: self, task_id, role, }
  let observer = @work.TicketActivityObserver::{ run, }
  observer.run.activity("start", "Started as " + role)
  let mcp_exts = self.mcp_face(role)
  let composer = CetasChildComposer::CetasChildComposer(
    parent_manager=self.manager,
    parent_mode=self.parent_mode,
    child_store=Some(store),
    approval=self.approval,
    ui=None,
    question=None,
    question_endpoint=Some(endpoint as &@askquestion.QuestionEndpoint),
    reporting=Some(reporting as &TicketReportEndpoint),
    extra_exts=mcp_exts,
    context_fs=self.ctx.fs,
    feature_fs=self.ctx.fs,
    cwd=self.ctx.cwd,
    home=self.ctx.home,
    host_group=Some(self.group),
  )
  let prompt = worker_prompt(task, role, resuming, self.runs_for(task_id))
  let name = match role {
    "rd" => self.team.rd
    "set" => self.team.set
    _ => self.team.te
  }
  let spec : @subagent.ChildSpec = {
    task: prompt,
    kind_name: "ticket-" + role,
    session_id,
    resuming,
    tools: Some(worker_tools(role)),
    skills: self.skill_face(role),
    mode: (self.parent_mode)(),
    system_prompt: ticket_system_prompt(
      self.ctx.cwd,
      development_system_prompt(name, role, self.profile),
    ),
    slot,
    effort,
    context_files: false,
    observers: [observer as &@posoco.Observer],
  }
  let agent = @subagent.ChildComposer::compose(composer, spec) catch {
    error => {
      let detail = match error {
        @subagent.Failed(detail) => detail
      }
      run.status = "failed"
      run.error = Some(detail)
      return Err(role + " composition failed: " + detail)
    }
  }
  self.group.spawn_bg(async fn() {
    let outcome : Result[String, String] = Ok(
      agent.run_scoped(async fn(agent) {
        agent.set_active_session(Some(session_id))
        let result = agent.run_turn(
          @posoco.Message::UserMessage(content=[@posoco.Content::Text(prompt)]),
          session_id,
        )
        match result.message {
          @posoco.Message::AssistantMessage(content=blocks, ..) =>
            blocks
            .filter_map(block => {
              match block {
                @posoco.Content::Text(value) => Some(value)
                _ => None
              }
            })
            .join("\n")
          _ => "ticket turn completed"
        }
      }),
    ) catch {
      error => Err(error.to_string())
    }
    self.finish_work(task_id, role, outcome)
  })
  Ok(())
}

///|
/// Facts the Scrum Master must not have to rediscover: dependency state,
/// other running work, and open questions. The Board snapshot stays the
/// authority; this is only a compact projection for one consultation.
async fn TicketRuntime::coordination_brief(
  self : TicketRuntime,
  task_id : String,
  task : Json,
) -> String {
  let snapshot = match self.snapshot_sync() {
    Ok(snapshot) => snapshot
    Err(_) => return "Coordination brief unavailable: Board snapshot failed."
  }
  let tasks = match @work.BoardState::tasks_from_snapshot(snapshot) {
    Ok(state) => state.tasks
    Err(_) => return "Coordination brief unavailable: Board state failed."
  }
  let by_id : Map[String, Json] = Map([])
  for item in tasks {
    by_id[@work.task_field(item, "id")] = item
  }
  let deps : Array[String] = []
  match task {
    Object(fields) =>
      match fields.get("dependencies") {
        Some(Array(items)) =>
          for item in items {
            match item {
              String(id) if id != "" => deps.push(id)
              _ => ()
            }
          }
        _ => ()
      }
    _ => ()
  }
  let lines : Array[String] = []
  lines.push("Ticket stage: " + @work.task_field(task, "stage"))
  if deps.is_empty() {
    lines.push("Dependencies: none")
  } else {
    for id in deps {
      let state = match by_id.get(id) {
        Some(item) => @work.task_field(item, "stage")
        None => "missing"
      }
      lines.push("Dependency " + id + ": " + state)
    }
  }
  let running : Array[String] = []
  for id in by_id.keys() {
    if id != task_id {
      for run in self.runs_for(id) {
        if run.status == "running" {
          running.push(id + " (" + run.role + ")")
        }
      }
    }
  }
  if running.is_empty() {
    lines.push("Other running work: none")
  } else {
    lines.push("Other running work: " + running.join(", "))
  }
  let open_questions = match self.questions.json() {
    Array(items) => items.length()
    _ => 0
  }
  lines.push("Open questions: " + open_questions.to_string())
  lines.join("\n")
}

///|
async fn TicketRuntime::consult_sm(
  self : TicketRuntime,
  task_id : String,
  question : String,
) -> Result[Unit, String] {
  if self.run_for(task_id) is Some(run) && run.status == "running" {
    return Err("ticket is already running")
  }
  let question = question.trim().to_owned()
  if question == "" {
    return Err("Scrum Master needs a concrete question")
  }
  let (task, _) = match self.task_snapshot(task_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let session_id = @work.work_session_id(task_id, "sm")
  let store = self.child_store_for(task_id)
  let run = self.add_run(task_id, session_id, "advice", "sm")
  let observer = @work.TicketActivityObserver::{ run, }
  observer.run.activity("start", "Asked " + self.team.sm)
  let brief = self.coordination_brief(task_id, task)
  let prompt = "Ticket state:\n" +
    @work.one_line_preview(task.stringify(), 4000) +
    "\n\nCoordination brief:\n" +
    brief +
    "\n\nQuestion for the Scrum Master:\n" +
    question
  let composer = CetasChildComposer::CetasChildComposer(
    parent_manager=self.manager,
    parent_mode=self.parent_mode,
    child_store=Some(store),
    approval=self.approval,
    ui=None,
    question=None,
    question_endpoint=None,
    extra_exts=self.mcp_face("sm"),
    context_fs=self.ctx.fs,
    feature_fs=self.ctx.fs,
    cwd=self.ctx.cwd,
    home=self.ctx.home,
    host_group=Some(self.group),
  )
  let (slot, effort) = match @work.task_model(task) {
    Some(model) => (model.slot, model.effort)
    None =>
      (
        self.manager.manager_active_model_id(),
        self.manager.manager_active_effort(),
      )
  }
  let spec : @subagent.ChildSpec = {
    task: prompt,
    kind_name: "ticket-sm",
    session_id,
    resuming: true,
    tools: Some(["read", "glob", "grep", "astgrep"]),
    skills: self.skill_face("sm"),
    mode: (self.parent_mode)(),
    system_prompt: ticket_system_prompt(
      self.ctx.cwd,
      scrum_master_system_prompt(self.team.sm),
    ),
    slot,
    effort,
    context_files: false,
    observers: [observer as &@posoco.Observer],
  }
  let agent = @subagent.ChildComposer::compose(composer, spec) catch {
    error => {
      let detail = match error {
        @subagent.Failed(detail) => detail
      }
      run.status = "failed"
      run.error = Some(detail)
      return Err("Scrum Master composition failed: " + detail)
    }
  }
  self.group.spawn_bg(async fn() {
    let outcome : Result[String, String] = Ok(
      agent.run_scoped(async fn(agent) {
        agent.set_active_session(Some(session_id))
        let result = agent.run_turn(
          @posoco.Message::UserMessage(content=[@posoco.Content::Text(prompt)]),
          session_id,
        )
        match result.message {
          @posoco.Message::AssistantMessage(content=blocks, ..) =>
            blocks
            .filter_map(block => {
              match block {
                @posoco.Content::Text(value) => Some(value)
                _ => None
              }
            })
            .join("\n")
          _ => "Scrum Master answered"
        }
      }),
    ) catch {
      error => Err(error.to_string())
    }
    match outcome {
      Ok(answer) => {
        run.status = "done"
        run.result = Some(answer)
        self.record_progress(task_id, "advice", answer)
      }
      Err(error) => {
        run.status = "failed"
        run.error = Some(error)
        self.record_progress(
          task_id,
          "attention",
          "Scrum Master failed: " + error,
        )
      }
    }
  })
  Ok(())
}

///|
async fn TicketRuntime::run(
  self : TicketRuntime,
  task_id : String,
) -> Result[Unit, String] {
  let resuming = match self.resuming_task {
    Some(id) => id == task_id
    None => false
  }
  if self.run_for(task_id) is Some(run) && run.status == "running" {
    return Err("ticket is already running")
  }
  let (task, _) = match self.task_snapshot(task_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let stage = @work.task_field(task, "stage")
  if stage != "ready" && !(resuming && stage == "running") {
    return Err("ticket must be Ready before it can run")
  }
  if !resuming {
    if @work.task_field(task, "user_story").trim() == "" {
      return Err("Ready ticket needs a user story; shape it first")
    }
    if @work.task_field(task, "description").trim() == "" {
      return Err("Ready ticket needs a detailed description; shape it first")
    }
    if @work.task_field(task, "implementation_suggestions").trim() == "" {
      return Err(
        "Ready ticket needs implementation suggestions; shape it first",
      )
    }
    if @work.task_definition_of_done(task).is_empty() {
      return Err("Ready ticket needs a definition of done; shape it first")
    }
  }
  if !(resuming && stage == "running") {
    match self.move_task(task_id, "running") {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  let roles = @work.task_required_roles(task)
  if !roles.contains("rd") {
    return Err("Ready ticket needs RD in its role plan")
  }
  let starters = roles.filter(role => role == "rd" || role == "set")
  for role in starters {
    match self.start_role(task_id, task, role, resuming) {
      Ok(_) => ()
      Err(error) => {
        for other in starters {
          self.park_run(task_id, other, "failed", error)
        }
        return Err(error)
      }
    }
  }
  self.resuming_task = None
  Ok(())
}

///|
async fn TicketRuntime::resume_ticket(
  self : TicketRuntime,
  task_id : String,
) -> Result[Json, String] {
  if self.run_for(task_id) is Some(run) && run.status == "running" {
    return Err("ticket is already running")
  }
  let (task, _) = match self.task_snapshot(task_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let stage = @work.task_field(task, "stage")
  if stage != "ready" && stage != "running" && stage != "suspended" {
    return Err(
      "ticket must be Ready, Running, or Suspended before it can be resumed",
    )
  }
  let session_id = @work.work_session_id(task_id, "rd")
  let store = self.child_store_for(task_id)
  let session = store.load(session_id) catch {
    error =>
      return Err(
        "could not read the durable ticket session: " + error.to_string(),
      )
  }
  if session.messages.is_empty() {
    return Err("no durable ticket session to resume")
  }
  if stage == "suspended" {
    match self.move_task(task_id, "ready") {
      Ok(_) => ()
      Err(error) =>
        return Err(
          "could not move the ticket to Ready before resuming: " + error,
        )
    }
  }
  self.resuming_task = Some(task_id)
  match self.run(task_id) {
    Ok(_) => Ok(self.state_json())
    Err(error) => {
      self.resuming_task = None
      Err(error)
    }
  }
}

///|
/// Send one Review ticket back to work with reviewer feedback.
///
/// The review decision belongs to the attempt that is running right now, so
/// the host reads the latest Running Review attempt from the authoritative
/// snapshot instead of guessing one: with no such attempt there is nothing to
/// request changes on, and the rejection starts no work. `feedback` is the
/// reviewer's requirement, so it is trimmed and an empty body is rejected
/// before any Board command. `board.task.request_changes` records the
/// ChangesRequested decision, stores the feedback and moves Review -> Ready in
/// one revision; only after that is accepted does a fresh work run start.
/// Request changes is a new attempt, never a resume: `run` clears the previous
/// work session, so the worker starts from the ticket and the feedback alone.
async fn TicketRuntime::request_changes(
  self : TicketRuntime,
  task_id : String,
  feedback : String,
) -> Result[Json, String] {
  let text = feedback.trim().to_owned()
  if text.is_empty() {
    return Err("review feedback must not be empty")
  }
  let snapshot = match self.snapshot() {
    Ok(snapshot) => snapshot
    Err(error) => return Err(error)
  }
  let state = match @work.BoardState::from_snapshot(snapshot) {
    Ok(state) => state
    Err(error) => return Err(error)
  }
  if state.task(task_id) is None {
    return Err("ticket was not found")
  }
  if state.stage(task_id) != "review" {
    return Err("ticket must be under Review before changes can be requested")
  }
  let attempt_id = match state.latest_running_review_attempt(task_id) {
    Some(id) => id
    None =>
      return Err("ticket has no running review attempt to request changes on")
  }
  match
    self.board_command(
      "board.task.request_changes",
      { "id": Json::string(attempt_id), "feedback": Json::string(text) },
      state.revision,
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match self.run(task_id) {
    Ok(_) => Ok(self.state_json())
    Err(error) => Err(error)
  }
}

///|
/// Restart one stopped ticket on a fresh child session.
///
/// Only Ready, Review and Suspended may be retried: Running already owns a
/// session, and Done/Cancelled/Backlog are not work the host silently
/// restarts. Review and Suspended are first moved back to Ready, so the Board
/// records the restart before the new run claims Running; a failed move starts
/// nothing. The fresh run composes a new child session — retry never pretends
/// to resume the session a previous attempt lost.
async fn TicketRuntime::retry(
  self : TicketRuntime,
  task_id : String,
) -> Result[Json, String] {
  if self.run_for(task_id) is Some(run) && run.status == "running" {
    return Err("ticket is already running")
  }
  let (task, _) = match self.task_snapshot(task_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let stage = @work.task_field(task, "stage")
  if stage != "ready" &&
    stage != "verification" &&
    stage != "review" &&
    stage != "suspended" &&
    stage != "running" {
    return Err(
      "ticket must be Ready, Verification, Review, Suspended, or a failed Running ticket before it can be retried",
    )
  }
  if stage == "running" {
    match self.move_task(task_id, "suspended") {
      Ok(_) => ()
      Err(error) =>
        return Err("could not park the failed ticket before retrying: " + error)
    }
  }
  if stage != "ready" {
    match self.move_task(task_id, "ready") {
      Ok(_) => ()
      Err(error) => return Err("could not move the ticket to Ready: " + error)
    }
  }
  match self.run(task_id) {
    Ok(_) => Ok(self.state_json())
    Err(error) => Err(error)
  }
}

///|
fn TicketRuntime::dismiss(self : TicketRuntime, task_id : String) -> Unit {
  self.runs.dismiss(task_id)
}

///|
async fn TicketRuntime::run_ready(self : TicketRuntime) -> Result[Unit, String] {
  let snapshot = match self.snapshot() {
    Ok(snapshot) => snapshot
    Err(error) => return Err(error)
  }
  let state = match @work.BoardState::tasks_from_snapshot(snapshot) {
    Ok(state) => state
    Err(error) => return Err(error)
  }
  let mut started = 0
  let failures : Array[String] = []
  for task in state.tasks {
    if @work.task_field(task, "stage") == "ready" {
      let id = @work.task_field(task, "id")
      if id != "" {
        match self.run(id) {
          Ok(_) => started = started + 1
          Err(error) => failures.push(id + ": " + error)
        }
      }
    }
  }
  if started > 0 {
    Ok(())
  } else if failures.is_empty() {
    Err("no Ready ticket is waiting")
  } else {
    Err("no Ready ticket could start: " + failures.join("; "))
  }
}
