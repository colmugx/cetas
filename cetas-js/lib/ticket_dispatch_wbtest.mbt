///|
async test "ticket run dispatches a background child and moves the ticket to review" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("Ticket work completed with evidence."),
    ),
  ])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/ticket", model)],
    default_slot_id="test/ticket",
  )
  @async.with_task_group(group => {
    let fs = @workspace.JsWorkspaceFs()
    let ctx : @cetas_core.HostContext = { fs, cwd: directory, home: directory, }
    let board = @board.BoardWorkflows(
      directory~,
      group~,
      agents=customer_factory(router, directory, () => @permission.ReadOnly),
      authorize=() => true,
      policy=@board.BoardWorkflowPolicy(enabled=true),
    )
    defer ignore(board.shutdown())
    let tickets = TicketRuntime::TicketRuntime(
      board~,
      manager=Providers(router),
      parent_mode=() => @permission.ReadOnly,
      approval=None,
      ctx~,
      group~,
    )
    let create : Json = {
      "id": "task-1",
      "title": "Finish the ticket",
      "description": "Do the work",
      "priority": "normal",
      "definition_of_done": ["Evidence"],
      "dependencies": [],
    }
    let created = match
      board.wire_command(
        @board_protocol.encode_client_frame(
          @board_protocol.Command({
            command_id: "ticket-create-1",
            name: "board.task.create",
            expected_revision: 0L,
            args: create,
          }),
        ),
      ) {
      Ok(created) => created
      Err(error) => fail("create command failed: " + error.code())
    }
    match @board_protocol.decode_server_frame(created) {
      Ok(@board_protocol.CommandResult(result)) => assert_true(result.accepted)
      _ => fail("create command did not return a result")
    }
    let moved = match
      board.wire_command(
        @board_protocol.encode_client_frame(
          @board_protocol.Command({
            command_id: "ticket-move-1",
            name: "board.task.move",
            expected_revision: 1L,
            args: { "id": "task-1", "to": "refining" },
          }),
        ),
      ) {
      Ok(moved) => moved
      Err(error) => fail("move command failed: " + error.code())
    }
    match @board_protocol.decode_server_frame(moved) {
      Ok(@board_protocol.CommandResult(result)) => assert_true(result.accepted)
      _ => fail("move command did not return a result")
    }
    let ready = match
      board.wire_command(
        @board_protocol.encode_client_frame(
          @board_protocol.Command({
            command_id: "ticket-move-2",
            name: "board.task.move",
            expected_revision: 2L,
            args: { "id": "task-1", "to": "ready" },
          }),
        ),
      ) {
      Ok(ready) => ready
      Err(error) => fail("ready command failed: " + error.code())
    }
    match @board_protocol.decode_server_frame(ready) {
      Ok(@board_protocol.CommandResult(result)) => assert_true(result.accepted)
      _ => fail("ready command did not return a result")
    }
    match tickets.run("task-1") {
      Ok(_) => ()
      Err(error) => fail("ticket run failed: " + error)
    }
    let mut stage = ""
    for _ in 0..<100 {
      let snapshot = match
        @board_protocol.decode_server_frame(
          match board.wire_snapshot() {
            Ok(snapshot) => snapshot
            Err(error) => fail("snapshot failed: " + error.code())
          },
        ) {
        Ok(@board_protocol.Snapshot(snapshot)) => snapshot
        _ => fail("snapshot was invalid")
      }
      let board_json = match snapshot.payload {
        Object(payload) =>
          match payload.get("board") {
            Some(Object(board)) => board
            _ => fail("snapshot has no board")
          }
        _ => fail("snapshot payload is not an object")
      }
      let tasks = match board_json.get("tasks") {
        Some(Array(tasks)) => tasks
        _ => fail("snapshot has no tasks")
      }
      for task in tasks {
        if task_field(task, "id") == "task-1" {
          stage = task_field(task, "stage")
        }
      }
      if stage == "review" {
        break
      }
      @async.sleep(20)
    }
    assert_eq(stage, "review")
  })
}

///|
async test "ticket shaping can split an oversized ticket into ready children" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response(
        "{\"summary\":\"Three independent tickets\",\"tasks\":[{\"title\":\"Alpha\",\"description\":\"A\",\"definition_of_done\":[\"A done\"]},{\"title\":\"Beta\",\"description\":\"B\",\"definition_of_done\":[\"B done\"]},{\"title\":\"Gamma\",\"description\":\"C\",\"definition_of_done\":[\"C done\"]}]}",
      ),
    ),
  ])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/shape-split", model)],
    default_slot_id="test/shape-split",
  )
  @async.with_task_group(group => {
    let fs = @workspace.JsWorkspaceFs()
    let ctx : @cetas_core.HostContext = { fs, cwd: directory, home: directory, }
    let board = @board.BoardWorkflows(
      directory~,
      group~,
      agents=customer_factory(router, directory, () => @permission.ReadOnly),
      authorize=() => true,
      policy=@board.BoardWorkflowPolicy(enabled=true),
    )
    defer ignore(board.shutdown())
    let tickets = TicketRuntime::TicketRuntime(
      board~,
      manager=Providers(router),
      parent_mode=() => @permission.ReadOnly,
      approval=None,
      ctx~,
      group~,
    )
    let create : Json = {
      "id": "task-1",
      "title": "Oversized request",
      "description": "Three things in one",
      "priority": "normal",
      "definition_of_done": [],
      "dependencies": [],
    }
    ignore(
      board.wire_command(
        @board_protocol.encode_client_frame(
          @board_protocol.Command({
            command_id: "split-create-1",
            name: "board.task.create",
            expected_revision: 0L,
            args: create,
          }),
        ),
      ),
    )
    let refining = match
      board.wire_command(
        @board_protocol.encode_client_frame(
          @board_protocol.Command({
            command_id: "split-move-1",
            name: "board.task.move",
            expected_revision: 1L,
            args: { "id": "task-1", "to": "refining" },
          }),
        ),
      ) {
      Ok(encoded) => encoded
      Err(error) => fail("move command failed: " + error.code())
    }
    match @board_protocol.decode_server_frame(refining) {
      Ok(@board_protocol.CommandResult(result)) => assert_true(result.accepted)
      _ => fail("move command did not return a result")
    }
    let ready = match
      board.wire_command(
        @board_protocol.encode_client_frame(
          @board_protocol.Command({
            command_id: "split-move-2",
            name: "board.task.move",
            expected_revision: 2L,
            args: { "id": "task-1", "to": "ready" },
          }),
        ),
      ) {
      Ok(encoded) => encoded
      Err(error) => fail("ready command failed: " + error.code())
    }
    match @board_protocol.decode_server_frame(ready) {
      Ok(@board_protocol.CommandResult(result)) => assert_true(result.accepted)
      _ => fail("ready command did not return a result")
    }
    match tickets.shape("task-1") {
      Ok(_) => ()
      Err(error) => fail("ticket shape failed: " + error)
    }
    let mut source_present = true
    let mut split_count = 0
    let mut all_ready = false
    for _ in 0..<150 {
      let snapshot = match
        @board_protocol.decode_server_frame(
          match board.wire_snapshot() {
            Ok(snapshot) => snapshot
            Err(error) => fail("snapshot failed: " + error.code())
          },
        ) {
        Ok(@board_protocol.Snapshot(snapshot)) => snapshot
        _ => fail("snapshot was invalid")
      }
      let board_json = match snapshot.payload {
        Object(payload) =>
          match payload.get("board") {
            Some(Object(board)) => board
            _ => fail("snapshot has no board")
          }
        _ => fail("snapshot payload is not an object")
      }
      let tasks = match board_json.get("tasks") {
        Some(Array(tasks)) => tasks
        _ => fail("snapshot has no tasks")
      }
      source_present = false
      split_count = 0
      all_ready = true
      for task in tasks {
        let id = task_field(task, "id")
        if id == "task-1" {
          source_present = true
        } else if id.length() >= 6 && id[0:6] == "split-" {
          split_count = split_count + 1
          if task_field(task, "stage") != "ready" {
            all_ready = false
          }
        }
      }
      if !source_present && split_count == 3 && all_ready {
        break
      }
      @async.sleep(20)
    }
    assert_false(source_present)
    assert_eq(split_count, 3)
    assert_true(all_ready)
    let ticket_state = tickets.state_json().stringify()
    assert_true(ticket_state.contains("Step"))
  })
}

///|
async test "ticket shaping clarifies the ticket and moves it to ready" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response(
        "{\"summary\":\"Scope clarified\",\"description\":\"Clarified scope\",\"definition_of_done\":[\"A\",\"B\"]}",
      ),
    ),
  ])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/shape", model)],
    default_slot_id="test/shape",
  )
  @async.with_task_group(group => {
    let fs = @workspace.JsWorkspaceFs()
    let ctx : @cetas_core.HostContext = { fs, cwd: directory, home: directory, }
    let board = @board.BoardWorkflows(
      directory~,
      group~,
      agents=customer_factory(router, directory, () => @permission.ReadOnly),
      authorize=() => true,
      policy=@board.BoardWorkflowPolicy(enabled=true),
    )
    defer ignore(board.shutdown())
    let tickets = TicketRuntime::TicketRuntime(
      board~,
      manager=Providers(router),
      parent_mode=() => @permission.ReadOnly,
      approval=None,
      ctx~,
      group~,
    )
    let create : Json = {
      "id": "task-1",
      "title": "Shape me",
      "description": "Raw story",
      "priority": "normal",
      "definition_of_done": [],
      "dependencies": [],
    }
    ignore(
      board.wire_command(
        @board_protocol.encode_client_frame(
          @board_protocol.Command({
            command_id: "shape-create-1",
            name: "board.task.create",
            expected_revision: 0L,
            args: create,
          }),
        ),
      ),
    )
    match tickets.shape("task-1") {
      Ok(_) => ()
      Err(error) => fail("ticket shape failed: " + error)
    }
    let mut stage = ""
    let mut description = ""
    let mut done = 0
    for _ in 0..<100 {
      let snapshot = match
        @board_protocol.decode_server_frame(
          match board.wire_snapshot() {
            Ok(snapshot) => snapshot
            Err(error) => fail("snapshot failed: " + error.code())
          },
        ) {
        Ok(@board_protocol.Snapshot(snapshot)) => snapshot
        _ => fail("snapshot was invalid")
      }
      let board_json = match snapshot.payload {
        Object(payload) =>
          match payload.get("board") {
            Some(Object(board)) => board
            _ => fail("snapshot has no board")
          }
        _ => fail("snapshot payload is not an object")
      }
      let tasks = match board_json.get("tasks") {
        Some(Array(tasks)) => tasks
        _ => fail("snapshot has no tasks")
      }
      for task in tasks {
        if task_field(task, "id") == "task-1" {
          stage = task_field(task, "stage")
          description = task_field(task, "description")
          done = match task {
            Object(fields) =>
              match fields.get("definition_of_done") {
                Some(Array(items)) => items.length()
                _ => 0
              }
            _ => 0
          }
        }
      }
      if stage == "ready" && description == "Clarified scope" {
        break
      }
      @async.sleep(20)
    }
    assert_eq(stage, "ready")
    assert_eq(description, "Clarified scope")
    assert_eq(done, 2)
  })
}
