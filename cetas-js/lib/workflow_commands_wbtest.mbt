///|
priv struct WorkflowMenuUi {
  requests : Array[@posoco.UiRequest]
  mut failure : @posoco.UiError?
}

///|
impl @posoco.Extension for WorkflowMenuUi with fn extension_id(_) {
  "workflow-menu-ui"
}

///|
impl @posoco.Extension for WorkflowMenuUi with fn manifest(self) {
  @posoco.ExtensionManifest(id="workflow-menu-ui", ui=[self])
}

///|
impl @posoco.UiPort for WorkflowMenuUi with fn ui_descriptor(_) {
  @posoco.UiDescriptor::empty()
}

///|
impl @posoco.UiPort for WorkflowMenuUi with fn render(_, _) {
  ()
}

///|
impl @posoco.UiPort for WorkflowMenuUi with fn request(self, request) {
  self.requests.push(request)
  if self.failure is Some(error) {
    raise error
  }
  @posoco.UiResponse::Cancelled
}

///|
async test "workflow menu cancellation is read-only and exposes no second Board runtime" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  let model = @posoco.ScriptedModel([])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/workflow-menu", model)],
    default_slot_id="test/workflow-menu",
  )
  @async.with_task_group(group => {
    let agents = customer_factory(router, directory, () => {
      @permission.Interactive
    })
    let board = @board.BoardWorkflows(
      directory~,
      group~,
      agents~,
      policy=@board.BoardWorkflowPolicy(enabled=true),
    )
    let product = CetasWorkflowCommands::{
      board,
      agents,
      settings: @cetas_core.workflow_settings_from_json(
        "{\"workflow\":{\"enabled\":true}}",
      ),
      tickets: None,
      ui: None,
    }
    let ui = WorkflowMenuUi::{ requests: [], failure: None, }
    let agent = @posoco.Agent(
      exts=[router, ui, product],
      config=@cetas_core.default_agent_config(),
    )
    let result = (product as &@posoco.CommandPort).invoke("board.workflow", {})
    assert_true(result is @posoco.CommandOutcome::Success(_))
    assert_eq(ui.requests.length(), 1)
    guard ui.requests[0] is @posoco.UiRequest::Select(prompt~, options~, ..) else {
      fail("expected workflow menu")
    }
    assert_true(prompt.contains("opening this menu changes nothing"))
    assert_eq(options[0], "Start from a coding goal")
    assert_true(customer_checked(board.view()).snapshot.tasks.is_empty())
    assert_true(
      @workspace.read_file_result(
        @workspace.JsWorkspaceFs(),
        directory + "/execution.lock",
      )
      is @workspace.Missing,
    )
    assert_true(
      @workspace.read_file_result(
        @workspace.JsWorkspaceFs(),
        directory + "/board.json",
      )
      is @workspace.Missing,
    )
    for
      (error, expected) in [
        (@posoco.UiError::Cancelled, None),
        (
          @posoco.UiError::IoFailure(detail="UI request timed out"),
          Some("workflow_ui_request_timed_out"),
        ),
        (
          @posoco.UiError::IoFailure(detail="private transport detail"),
          Some("workflow_ui_request_failed"),
        ),
        (
          @posoco.UiError::Unsupported(detail="private unsupported detail"),
          Some("trusted_ui_required"),
        ),
        (
          @posoco.UiError::InvalidRequest(detail="private request detail"),
          Some("workflow_ui_invalid_request"),
        ),
      ] {
      ui.failure = Some(error)
      for action in ["board.workflow", "board.workflow.start"] {
        let outcome = (product as &@posoco.CommandPort).invoke(action, {})
        match expected {
          None => assert_true(outcome is @posoco.CommandOutcome::Success(_))
          Some(reason) => {
            guard outcome is @posoco.CommandOutcome::Failure(reason=actual) else {
              fail("UI failure was hidden")
            }
            assert_eq(actual, reason)
          }
        }
      }
    }
    assert_true(customer_checked(board.view()).snapshot.tasks.is_empty())
    assert_true(
      @workspace.read_file_result(
        @workspace.JsWorkspaceFs(),
        directory + "/execution.lock",
      )
      is @workspace.Missing,
    )
    assert_true(model.received_tools.is_empty())
    assert_eq(
      agent
      .commands()
      .filter(p => p.commands().any(d => d.id == "board.workflow"))
      .length(),
      1,
    )
    agent.shutdown()
  })
}

///|
async test "readonly guided start refuses before any input or approval prompt" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  let model = @posoco.ScriptedModel([])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/workflow-readonly", model)],
    default_slot_id="test/workflow-readonly",
  )
  @async.with_task_group(group => {
    let agents = customer_factory(router, directory, () => @permission.ReadOnly)
    let board = @board.BoardWorkflows(
      directory~,
      group~,
      agents~,
      authorize=() => false,
      policy=@board.BoardWorkflowPolicy(enabled=true),
    )
    let product = CetasWorkflowCommands::{
      board,
      agents,
      settings: @cetas_core.workflow_settings_from_json(
        "{\"workflow\":{\"enabled\":true}}",
      ),
      tickets: None,
      ui: None,
    }
    let ui = WorkflowMenuUi::{ requests: [], failure: None, }
    let agent = @posoco.Agent(
      exts=[router, ui, product],
      config=@cetas_core.default_agent_config(),
    )
    assert_true(
      (product as &@posoco.CommandPort).invoke("board.workflow.start", {})
      is @posoco.CommandOutcome::Failure(reason="approval_denied"),
    )
    for action in ["start", "run", "graph.approve", "scope.approve", "prepare"] {
      for
        args in [({ "unexpected": true } : Json), Json::array([]), Json::null()] {
        let result = (product as &@posoco.CommandPort).invoke(
          "board.workflow." + action,
          args,
        )
        assert_true(
          result
          is @posoco.CommandOutcome::Failure(
            reason="Board commands accept trusted UI decisions, not executable JSON arguments"
          ),
        )
      }
    }
    assert_true(ui.requests.is_empty())
    assert_true(customer_checked(board.view()).snapshot.tasks.is_empty())
    agent.shutdown()
  })
}

///|
test "workflow labels neutralize terminal controls without changing task identity" {
  assert_eq(workflow_label("a\u001b[31m\u009bb\nnext"), "a [31m b next")
  assert_eq(workflow_label("中文 😀"), "中文 😀")
}

///|
test "workflow menu treats the real Stopped phase as terminal" {
  for
    phase in [
      @board_workflow.Stopped,
      @board_workflow.Completed,
      @board_workflow.Failed,
      @board_workflow.Unresolved,
    ] {
    assert_true(workflow_terminal(phase))
  }
  for
    phase in [
      @board_workflow.Idle,
      @board_workflow.Running,
      @board_workflow.Pausing,
      @board_workflow.Paused,
      @board_workflow.Stopping,
    ] {
    assert_false(workflow_terminal(phase))
  }
}

///|
test "ticket model command argument parses pin, inherit and malformed shapes" {
  match parse_ticket_model_arg(Json::null()) {
    Ok(None) => ()
    _ => fail("null must mean inherit")
  }
  match parse_ticket_model_arg({ "slot": "openai/gpt-5.2", "effort": "high" }) {
    Ok(Some(model)) => {
      assert_eq(model.slot, "openai/gpt-5.2")
      assert_eq(model.effort, Some("high"))
    }
    _ => fail("expected a pinned model")
  }
  assert_true(parse_ticket_model_arg({ "slot": "" }) is Err(_))
  assert_true(parse_ticket_model_arg({ "slot": "x", "extra": 1 }) is Err(_))
  assert_true(parse_ticket_model_arg("not-a-model") is Err(_))
}

///|
/// One field of a projected JSON object, or `None`.
fn board_work_field(value : Json, key : String) -> Json? {
  match value {
    Object(fields) => fields.get(key)
    _ => None
  }
}

///|
fn board_work_named_call(
  name : String,
  arguments : Json,
) -> @posoco.ToolCallContext {
  {
    effect_id: @kernel.EffectId::{ value: 21, },
    call_id: @posoco.CallId::unchecked("call-" + name),
    name: @posoco.ToolName::unchecked(name),
    arguments,
    register_cancel: fn(_ : &@posoco.ToolCancellable) { () },
  }
}

///|
/// One `board_work` call context, the way the runtime hands it over.
fn board_work_call(arguments : Json) -> @posoco.ToolCallContext {
  board_work_named_call("board_work", arguments)
}

///|
/// One `board_work` call through the real tool trait. A raised `RuntimeError`
/// propagates to the test, exactly as the runtime surfaces it.
async fn board_work_outcome(
  product : CetasWorkflowCommands,
  arguments : Json,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  @posoco.ToolProvider::execute(product, board_work_call(arguments))
}

///|
test "board_work is one read-only sequential tool with a bounded schema" {
  let def = board_work_tool_def()
  assert_eq(def.name.to_string(), "board_work")
  assert_eq(def.owner.to_string(), "cetas_board")
  assert_eq(def.provenance, Some("cetas_board"))
  assert_true(def.policy is @posoco.ExecutionPolicy::Sequential)
  assert_true(def.description.contains("Read-only"))
  let schema = def.input_schema
  assert_eq(
    board_work_field(schema, "required").unwrap(),
    Json::array([Json::string("action")]),
  )
  let properties = board_work_field(schema, "properties").unwrap()
  for key in ["action", "path", "ticket", "limit"] {
    assert_true(board_work_field(properties, key) is Some(_))
  }
  assert_eq(
    board_work_field(board_work_field(properties, "action").unwrap(), "enum").unwrap(),
    Json::array(["status", "history", "review"].map(Json::string)),
  )
}

///|
test "board_work arguments reject unknown actions and clamp the limit" {
  assert_true(parse_board_work_arguments(Json::null()) is Err(_))
  assert_true(parse_board_work_arguments({ "action": "delete" }) is Err(_))
  // A history with no filter would be a whole-board dump.
  assert_true(parse_board_work_arguments({ "action": "history" }) is Err(_))
  assert_true(
    parse_board_work_arguments({ "action": "status", "limit": "many" })
    is Err(_),
  )
  assert_true(
    parse_board_work_arguments({ "action": "status", "path": "  " }) is Err(_),
  )
  match parse_board_work_arguments({ "action": "status" }) {
    Ok(query) => assert_eq(query.limit, board_work_limit_default)
    Err(reason) => fail(reason)
  }
  match parse_board_work_arguments({ "action": "status", "limit": 99 }) {
    Ok(query) => assert_eq(query.limit, board_work_limit_max)
    Err(reason) => fail(reason)
  }
  match parse_board_work_arguments({ "action": "status", "limit": 0 }) {
    Ok(query) => assert_eq(query.limit, 1)
    Err(reason) => fail(reason)
  }
  match
    parse_board_work_arguments({ "action": "history", "path": "src/X.mbt" }) {
    Ok(query) => assert_eq(query.path, Some("src/X.mbt"))
    Err(reason) => fail(reason)
  }
  match parse_board_work_arguments({ "action": "review", "ticket": " t1 " }) {
    Ok(query) => assert_eq(query.ticket, Some("t1"))
    Err(reason) => fail(reason)
  }
}

///|
test "board_work snapshot parsing rejects malformed frames" {
  assert_true(board_work_snapshot("not json") is Err(_))
  assert_true(board_work_snapshot("[]") is Err(_))
  assert_true(board_work_snapshot("{\"type\":\"snapshot\"}") is Err(_))
  assert_true(board_work_snapshot("{\"payload\":{\"board\":{}}}") is Err(_))
  assert_true(
    board_work_snapshot("{\"payload\":{\"board\":{\"tasks\":{}}}}") is Err(_),
  )
  assert_true(
    board_work_snapshot("{\"payload\":{\"board\":{\"tasks\":[{}]}}}") is Err(_),
  )
  // A report that is not the committed wire shape is malformed, never empty.
  assert_true(
    board_work_snapshot(
      "{\"payload\":{\"board\":{\"tasks\":[{\"id\":\"t1\",\"title\":\"T\",\"stage\":\"running\",\"priority\":\"normal\",\"review\":{\"outcome\":\"o\"}}]}}}",
    )
    is Err(_),
  )
  match
    board_work_snapshot(
      "{\"payload\":{\"board\":{\"revision\":3,\"tasks\":[]}}}",
    ) {
    Ok(snapshot) => {
      assert_eq(snapshot.revision.stringify(), "3")
      assert_true(snapshot.tickets.is_empty())
    }
    Err(reason) => fail(reason)
  }
}

///|
/// The structured payload of one successful `board_work` call.
async fn board_work_json(
  product : CetasWorkflowCommands,
  arguments : Json,
) -> Json raise @posoco.RuntimeError {
  match board_work_outcome(product, arguments) {
    @posoco.ToolOutcome::Success(structured=Some(structured), ..) => structured
    @posoco.ToolOutcome::Success(..) =>
      abort("board_work returned no structured result")
    other => abort("board_work did not succeed: " + other.summary())
  }
}

///|
/// The visible business error of one `board_work` call.
async fn board_work_error(
  product : CetasWorkflowCommands,
  arguments : Json,
) -> String raise @posoco.RuntimeError {
  match board_work_outcome(product, arguments) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => content
    other => abort("board_work must report a visible error: " + other.summary())
  }
}

///|
/// Commit one Board command at the Board's current revision.
async fn board_work_commit(
  board : @board.BoardWorkflows,
  name : String,
  args : Json,
) -> Unit {
  accept_board_command(
    board,
    "board-work-" + name,
    name,
    board_revision_now(board),
    args,
  )
}

///|
/// Seed one Running ticket with the review report the test needs. Nothing about
/// the report is guessed: the test states its changes and artifacts.
async fn board_work_seed_ticket(
  board : @board.BoardWorkflows,
  id : String,
  title : String,
  changes : Array[String],
  artifacts : Array[Json],
) -> Unit {
  board_work_commit(
    board,
    "board.task.create",
    Json::object({
      "id": Json::string(id),
      "title": Json::string(title),
      "description": Json::string(""),
      "priority": Json::string("normal"),
      "definition_of_done": Json::array([]),
      "dependencies": Json::array([]),
    }),
  )
  for stage in ["refining", "ready", "running"] {
    board_work_commit(
      board,
      "board.task.move",
      Json::object({ "id": Json::string(id), "to": Json::string(stage) }),
    )
  }
  board_work_commit(
    board,
    "board.task.set_review_report",
    Json::object({
      "id": Json::string(id),
      "review": Json::object({
        "outcome": Json::string("Outcome " + id),
        "summary": Json::string("Summary " + id),
        "changes": Json::array(changes.map(Json::string)),
        "verification": Json::array([]),
        "risks": Json::array([]),
        "notes": Json::array([]),
        "open_questions": Json::array([]),
        "artifacts": Json::array(artifacts),
      }),
    }),
  )
}

///|
async test "board_work reads durable ticket provenance and filters by review path" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  let model = @posoco.ScriptedModel([])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/board-work", model)],
    default_slot_id="test/board-work",
  )
  @async.with_task_group(group => {
    let agents = customer_factory(router, directory, () => @permission.ReadOnly)
    let board = @board.BoardWorkflows(
      directory~,
      group~,
      agents~,
      policy=@board.BoardWorkflowPolicy(enabled=true),
    )
    defer ignore(board.shutdown())
    let product = CetasWorkflowCommands::{
      board,
      agents,
      settings: @cetas_core.workflow_settings_from_json(
        "{\"workflow\":{\"enabled\":true}}",
      ),
      tickets: None,
      ui: None,
    }
    board_work_seed_ticket(
      board,
      "ticket-path",
      "Fix the widget",
      ["Edited src/App/Widget.mbt"],
      [
        Json::object({
          "kind": Json::string("file"),
          "label": Json::string("widget"),
          "uri_or_digest": Json::string("src/App/Widget.mbt"),
        }),
      ],
    )
    board_work_seed_ticket(
      board,
      "ticket-other",
      "Write the guide",
      ["Edited docs/guide.md"],
      [
        Json::object({
          "kind": Json::string("file"),
          "label": Json::string("guide"),
          "uri_or_digest": Json::string("docs/guide.md"),
        }),
      ],
    )
    board_work_commit(
      board,
      "board.task.create",
      Json::object({
        "id": Json::string("ticket-idle"),
        "title": Json::string("Unstarted idea"),
        "description": Json::string(""),
        "priority": Json::string("low"),
        "definition_of_done": Json::array([]),
        "dependencies": Json::array([]),
      }),
    )
    let revision = board_revision_now(board)
    // One tool, declared once by the workflow extension's manifest.
    assert_eq(@posoco.ToolProvider::list_tools(product).length(), 1)
    let manifest = @posoco.Extension::manifest(product)
    assert_eq(manifest.id, board.extension_id())
    assert_eq(manifest.tools.length(), 1)
    // No `/workflow` definition exists, and every Board command is internal:
    // registered, callable by canonical id, but never user-discoverable.
    let definitions = (product as &@posoco.CommandPort).commands()
    assert_true(
      definitions.any(definition => definition.id == "board.workflow"),
    )
    assert_true(
      definitions.any(definition => definition.id == "board.workflow.status"),
    )
    assert_true(definitions.all(definition => definition.id != "workflow"))
    for
      definition in definitions.filter(definition => {
        definition.id.has_prefix("board.")
      }) {
      assert_false(definition.visible)
      assert_true(definition.aliases.is_empty())
    }
    // status: identity, stage, priority and the committed review summary.
    let status = board_work_json(product, { "action": "status" })
    let tasks = report_json_array(status, "tasks")
    assert_eq(tasks.length(), 3)
    assert_eq(report_json_text(tasks[0], "id"), "ticket-path")
    assert_eq(report_json_text(tasks[0], "title"), "Fix the widget")
    assert_eq(report_json_text(tasks[0], "stage"), "running")
    assert_eq(report_json_text(tasks[0], "priority"), "normal")
    assert_eq(
      report_json_text(tasks[0], "review_summary"),
      "Summary ticket-path",
    )
    // No report, no review summary: provenance is never invented.
    assert_eq(report_json_text(tasks[2], "review_summary"), "")
    assert_eq(
      report_json_array(
        board_work_json(product, { "action": "status", "limit": 2 }),
        "tasks",
      ).length(),
      2,
    )
    // history: the report's own changes and artifacts, matched
    // case-insensitively.
    let history = board_work_json(product, {
      "action": "history",
      "path": "SRC/app/Widget.MBT",
    })
    let matches = report_json_array(history, "matches")
    assert_eq(matches.length(), 1)
    assert_eq(report_json_text(matches[0], "ticket"), "ticket-path")
    assert_eq(report_json_text(matches[0], "title"), "Fix the widget")
    assert_eq(report_json_text(matches[0], "stage"), "running")
    assert_eq(
      report_json_text(matches[0], "review_summary"),
      "Summary ticket-path",
    )
    assert_eq(report_json_array(matches[0], "changes"), [
      Json::string("Edited src/App/Widget.mbt"),
    ])
    let artifacts = report_json_array(matches[0], "artifacts")
    assert_eq(artifacts.length(), 1)
    assert_eq(
      report_json_text(artifacts[0], "uri_or_digest"),
      "src/App/Widget.mbt",
    )
    assert_eq(report_json_text(matches[0], "review_feedback"), "")
    // A miss is a successful empty result, not an error and not a mutation.
    match
      board_work_outcome(product, {
        "action": "history",
        "path": "no/such/path",
      }) {
      @posoco.ToolOutcome::Success(content~, structured=Some(json)) => {
        assert_true(report_json_array(json, "matches").is_empty())
        assert_true(content.contains("No committed Board review matches"))
      }
      _ => fail("a history miss must be a successful empty result")
    }
    // The ticket filter also reaches a ticket whose report mentions no path.
    let by_ticket = board_work_json(product, {
      "action": "history",
      "ticket": "ticket-idle",
    })
    let idle = report_json_array(by_ticket, "matches")
    assert_eq(idle.length(), 1)
    assert_eq(report_json_text(idle[0], "ticket"), "ticket-idle")
    assert_true(report_json_array(idle[0], "changes").is_empty())
    assert_true(report_json_array(idle[0], "artifacts").is_empty())
    assert_eq(report_json_text(idle[0], "review_summary"), "")
    // review: one ticket's committed report and review feedback.
    let review = board_work_json(product, {
      "action": "review",
      "ticket": "ticket-path",
    })
    assert_eq(report_json_text(review, "ticket"), "ticket-path")
    assert_eq(report_json_text(review, "stage"), "running")
    let report = board_work_field(review, "review").unwrap()
    assert_eq(report_json_text(report, "outcome"), "Outcome ticket-path")
    assert_eq(report_json_text(report, "summary"), "Summary ticket-path")
    assert_eq(report_json_array(report, "artifacts").length(), 1)
    assert_eq(report_json_text(review, "review_feedback"), "")
    assert_eq(
      board_work_field(
        board_work_json(product, { "action": "review", "ticket": "ticket-idle" }),
        "review",
      ).unwrap(),
      Json::null(),
    )
    // Errors are visible and corrective.
    assert_true(
      board_work_error(product, {
        "action": "review",
        "ticket": "no-such-ticket",
      }).contains("no Board ticket with id 'no-such-ticket'"),
    )
    assert_true(
      board_work_error(product, { "action": "review" }).contains(
        "'review' needs a 'ticket'",
      ),
    )
    assert_true(
      board_work_error(product, { "action": "archive" }).contains(
        "'action' must be one of status, history, review",
      ),
    )
    let unknown : Result[@posoco.ToolOutcome, @posoco.RuntimeError] = Ok(
      @posoco.ToolProvider::execute(
        product,
        board_work_named_call("board_task_move", Json::object({})),
      ),
    ) catch {
      error => Err(error)
    }
    match unknown {
      Err(@posoco.RuntimeError::UnknownTool(message)) =>
        assert_true(message.contains("unknown tool 'board_task_move'"))
      _ => fail("an unknown tool name must be raised visibly")
    }
    // Read-only: no Board revision moved and no model turn ran.
    assert_eq(board_revision_now(board), revision)
    assert_true(model.received_tools.is_empty())
  })
}
