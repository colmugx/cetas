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
