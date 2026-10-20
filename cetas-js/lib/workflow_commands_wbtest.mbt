///|
priv struct WorkflowMenuUi {
  requests : Array[@posoco.UiRequest]
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
    let ui = WorkflowMenuUi::{ requests: [], }
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
    let ui = WorkflowMenuUi::{ requests: [], }
    let agent = @posoco.Agent(
      exts=[router, ui, product],
      config=@cetas_core.default_agent_config(),
    )
    assert_true(
      (product as &@posoco.CommandPort).invoke("board.workflow.start", {})
      is @posoco.CommandOutcome::Failure(reason="approval_denied"),
    )
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
