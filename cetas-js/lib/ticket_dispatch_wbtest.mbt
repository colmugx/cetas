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
