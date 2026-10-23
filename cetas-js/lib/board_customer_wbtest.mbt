///|
struct WorkflowCustomerUi {
  prompts : Array[String]
}

///|
impl @posoco.Extension for WorkflowCustomerUi with fn extension_id(_) {
  "cetas-workflow-test-ui"
}

///|
impl @posoco.Extension for WorkflowCustomerUi with fn manifest(self) {
  @posoco.ExtensionManifest(id="cetas-workflow-test-ui", ui=[self])
}

///|
impl @posoco.UiPort for WorkflowCustomerUi with fn ui_descriptor(_) {
  @posoco.UiDescriptor::empty()
}

///|
impl @posoco.UiPort for WorkflowCustomerUi with fn render(_, _) {
  ()
}

///|
impl @posoco.UiPort for WorkflowCustomerUi with fn request(self, request) {
  match request {
    @posoco.UiRequest::Confirm(prompt~) => {
      self.prompts.push(prompt)
      @posoco.UiResponse::Yes
    }
    _ => @posoco.UiResponse::Cancelled
  }
}

///|
fn[T, E] customer_checked(value : Result[T, E]) -> T raise {
  match value {
    Ok(value) => value
    Err(_) => fail("unexpected workflow failure")
  }
}

///|
fn customer_factory(
  router : @llm.RouterModelPort,
  directory : String,
  mode : () -> @permission.PermissionMode,
) -> CetasWorkflowAgents {
  {
    manager: Providers(router),
    parent_mode: mode,
    approval: None,
    ctx: { fs: @workspace.JsWorkspaceFs(), cwd: directory, home: directory, },
    selections: Map([]),
    host_group: None,
  }
}

///|
async test "Cetas JS factory drives real Agent plan graph scope preparation and execution" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  let payload : Json = {
    "schema_version": 1,
    "proposal_id": "customer-proposal",
    "parent_task_id": "workflow-100-0-root-1",
    "base_revision": 4,
    "tasks": [
      {
        "key": "work",
        "title": "Verify implementation",
        "description": "Untrusted task metadata",
        "priority": "normal",
        "definition_of_done": ["Evidence verified"],
        "depends_on": [],
      },
    ],
  }
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response(payload.stringify()),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("Actual controlled execution evidence"),
    ),
  ])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/board", model)],
    default_slot_id="test/board",
  )
  @async.with_task_group(group => {
    let ui = WorkflowCustomerUi::{ prompts: [], }
    let board = @board.BoardWorkflows(
      directory~,
      group~,
      agents=customer_factory(router, directory, () => @permission.ReadOnly),
      policy=@board.BoardWorkflowPolicy(
        enabled=true,
        max_concurrency=1,
        execution_timeout_ms=1000,
        max_elapsed_ms=10000,
      ),
      now_ms=() => 100L,
    )
    defer ignore(board.shutdown())
    let agent = @posoco.Agent(
      exts=[router, ui, board],
      config=@cetas_core.default_agent_config(),
    )
    let started = customer_checked(board.start(title="Validate configuration"))
    let root = started.snapshot.tasks[0].id.value
    ignore(
      customer_checked(
        board.propose(parent=root, requirements="trusted coding request"),
      ),
    )
    assert_true(model.received_tools[0].is_empty())
    let committed = customer_checked(board.graph_decision(grant=true))
    let expansion = committed.snapshot.expansions[0]
    let task = expansion.mapping[0].task_id.value
    assert_eq(
      committed.snapshot.tasks.filter(t => t.id.value == task)[0].stage,
      @board_domain.Created,
    )
    assert_eq(committed.snapshot.attempts.length(), 1)
    assert_true(board.prepare(task_id=task, input="unapproved input") is Err(_))
    ignore(
      customer_checked(
        board.scope_decision(
          expansion_id=expansion.expansion_id.value,
          grant=true,
        ),
      ),
    )
    ignore(
      customer_checked(
        board.prepare(task_id=task, input="trusted execution input"),
      ),
    )
    ignore(customer_checked(board.run_wave()))
    let settled = customer_checked(board.wait_boundary())
    assert_eq(settled.executions.length(), 2)
    assert_true(
      settled.executions.all(e => e.phase == @board_execution.Settled),
    )
    assert_eq(
      settled.snapshot.attempts.filter(a => a.task_id.value == task)[0].status,
      @board_domain.Succeeded,
    )
    assert_eq(
      settled.snapshot.tasks.filter(t => t.id.value == task)[0].stage,
      @board_domain.Ready,
    )
    let tools = model.received_tools[1].map(d => d.name.to_string())
    assert_true(tools.contains("read"))
    assert_false(tools.contains("agent"))
    assert_false(tools.contains("board.workflow.run"))
    assert_true(ui.prompts.any(p => p.contains("GRAPH APPROVAL")))
    assert_true(ui.prompts.any(p => p.contains("EXECUTION SCOPE APPROVAL")))
    agent.shutdown()
  })
}

///|
async test "Cetas Board is absent by default and readonly cannot acquire workflow authority" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  let model = @posoco.ScriptedModel([])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/board", model)],
    default_slot_id="test/board",
  )
  @async.with_task_group(group => {
    let ctx : @cetas_core.HostContext = {
      fs: @workspace.JsWorkspaceFs(),
      cwd: directory,
      home: directory,
    }
    assert_true(
      build_cetas_workflows(
        manager=Providers(router),
        parent_mode=() => @permission.ReadOnly,
        approval=None,
        ctx~,
        group~,
      )
      is None,
    )
    let board = @board.BoardWorkflows(
      directory~,
      group~,
      agents=customer_factory(router, directory, () => @permission.ReadOnly),
      authorize=() => false,
      policy=@board.BoardWorkflowPolicy(enabled=true),
    )
    defer ignore(board.shutdown())
    let ui = WorkflowCustomerUi::{ prompts: [], }
    let agent = @posoco.Agent(
      exts=[router, ui, board],
      config=@cetas_core.default_agent_config(),
    )
    assert_true(
      board.start(title="Denied")
      is Err(@board.BoardWorkflowError::ApprovalDenied),
    )
    assert_true(customer_checked(board.view()).snapshot.tasks.is_empty())
    assert_true(model.received_tools.is_empty())
    agent.shutdown()
  })
}

///|
async test "workflow model selection is isolated and pinned across child compositions" {
  let a = @posoco.ScriptedModel([])
  let b = @posoco.ScriptedModel([])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/a", a), subagent_test_slot("test/b", b)],
    default_slot_id="test/a",
  )
  let factory = customer_factory(router, ".", () => @permission.ReadOnly)
  let context : @board.WorkflowAgentContext = {
    purpose: @board.WorkflowAgentPurpose::Planning,
    workflow_id: "wf",
    task_id: "task",
    attempt_id: "plan",
    session_id: "session",
    slot: 0,
  }
  let first = @board.WorkflowAgentFactory::prepare(factory, context)
  router.switch_slot("test/b")
  let second = @board.WorkflowAgentFactory::prepare(factory, context)
  assert_eq(factory.selections.get("wf"), Some(("test/a", None)))
  assert_false(physical_equal(first.extensions[0], second.extensions[0]))
  assert_true(first.extensions.all(e => e.manifest().tools.is_empty()))
  assert_eq(router.active_slot_id(), "test/b")
}
