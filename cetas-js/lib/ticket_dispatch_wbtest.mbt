///|
fn task_model_slot(task : Json) -> String {
  match task {
    Object(fields) =>
      match fields.get("model") {
        Some(Object(model)) =>
          match model.get("slot") {
            Some(String(value)) => value
            _ => ""
          }
        _ => ""
      }
    _ => ""
  }
}

///|
/// The `review` object a Board snapshot task carries, or `None` while the
/// ticket has no durable report.
fn task_review(task : Json) -> Json? {
  match task {
    Object(fields) =>
      match fields.get("review") {
        Some(Object(review)) => Some(Json::object(review))
        _ => None
      }
    _ => None
  }
}

///|
fn review_field(review : Json, key : String) -> String {
  match review {
    Object(fields) =>
      match fields.get(key) {
        Some(String(value)) => value
        _ => ""
      }
    _ => ""
  }
}

///|
async test "ticket run dispatches a background child and moves the ticket to review" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  // RD and SET start together, so the first two stops are interchangeable;
  // TE runs last and its result is the review report.
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response(
        "Product change ready for independent verification.",
      ),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("Independent verification passed."),
    ),
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
      "user_story": "As a user, I want this ticket, so that it delivers value.",
      "implementation_suggestions": "Start with the acceptance criteria.",
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
    let mut has_review = false
    let mut review_outcome = ""
    let mut review_summary = ""
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
        if @work.task_field(task, "id") == "task-1" {
          stage = @work.task_field(task, "stage")
          match task_review(task) {
            Some(review) => {
              has_review = true
              review_outcome = review_field(review, "outcome")
              review_summary = review_field(review, "summary")
            }
            None => {
              has_review = false
              review_outcome = ""
              review_summary = ""
            }
          }
        }
      }
      if stage == "review" {
        break
      }
      @async.sleep(20)
    }
    if stage != "review" {
      fail(
        "ticket did not reach review: " +
        tickets.state_json().stringify() +
        " (stage " +
        stage +
        ")",
      )
    }
    assert_eq(stage, "review")
    assert_true(has_review)
    assert_true(review_outcome.contains("Ticket work completed with evidence."))
    assert_true(review_summary.contains("Ticket work completed with evidence."))
  })
}

///|
async test "ticket shaping can split an oversized ticket into ready children and cancel the source" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response(
        "{\"summary\":\"Three independent tickets\",\"tasks\":[{\"title\":\"Alpha\",\"user_story\":\"As a user, I want Alpha, so that A.\",\"description\":\"A\",\"implementation_suggestions\":\"Start with A\",\"definition_of_done\":[\"A done\"],\"priority\":\"p1\"},{\"title\":\"Beta\",\"user_story\":\"As a user, I want Beta, so that B.\",\"description\":\"B\",\"implementation_suggestions\":\"Start with B\",\"definition_of_done\":[\"B done\"],\"priority\":\"p2\"},{\"title\":\"Gamma\",\"user_story\":\"As a user, I want Gamma, so that C.\",\"description\":\"C\",\"implementation_suggestions\":\"Start with C\",\"definition_of_done\":[\"C done\"],\"priority\":\"p3\"}]}",
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
      "user_story": "As a user, I want this ticket, so that it delivers value.",
      "implementation_suggestions": "Start with the acceptance criteria.",
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
    let pinned = match
      board.wire_command(
        @board_protocol.encode_client_frame(
          @board_protocol.Command({
            command_id: "split-set-model",
            name: "board.task.set_model",
            expected_revision: 3L,
            args: {
              "id": "task-1",
              "model": { "slot": "test/shape-split", "effort": Json::null() },
            },
          }),
        ),
      ) {
      Ok(encoded) => encoded
      Err(error) => fail("set model command failed: " + error.code())
    }
    match @board_protocol.decode_server_frame(pinned) {
      Ok(@board_protocol.CommandResult(result)) => assert_true(result.accepted)
      _ => fail("set model command did not return a result")
    }
    match tickets.shape("task-1") {
      Ok(_) => ()
      Err(error) => fail("ticket shape failed: " + error)
    }
    let mut source_present = true
    let mut source_stage = ""
    let mut split_count = 0
    let mut all_ready = false
    let mut all_shaped = true
    let mut all_pinned = true
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
      source_stage = ""
      split_count = 0
      all_ready = true
      all_shaped = true
      all_pinned = true
      for task in tasks {
        let id = @work.task_field(task, "id")
        if id == "task-1" {
          source_present = true
          source_stage = @work.task_field(task, "stage")
        } else if id.length() >= 6 && id[0:6] == "split-" {
          split_count = split_count + 1
          if @work.task_field(task, "stage") != "ready" {
            all_ready = false
          }
          if @work.task_field(task, "user_story") == "" ||
            @work.task_field(task, "implementation_suggestions") == "" {
            all_shaped = false
          }
          if task_model_slot(task) != "test/shape-split" {
            all_pinned = false
          }
        }
      }
      if source_present &&
        source_stage == "cancelled" &&
        split_count == 3 &&
        all_ready &&
        all_shaped &&
        all_pinned {
        break
      }
      @async.sleep(20)
    }
    assert_true(source_present)
    assert_eq(source_stage, "cancelled")
    assert_eq(split_count, 3)
    assert_true(all_ready)
    assert_true(all_shaped)
    assert_true(all_pinned)
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
        "{\"summary\":\"Scope clarified\",\"title\":\"Clarified ticket\",\"user_story\":\"As a user, I want the clarified ticket, so that the scope is clear.\",\"description\":\"Clarified scope\",\"implementation_suggestions\":\"Start with the clarified scope\",\"definition_of_done\":[\"A\",\"B\"],\"priority\":\"p1\"}",
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
      "user_story": "As a user, I want this ticket, so that it delivers value.",
      "implementation_suggestions": "Start with the acceptance criteria.",
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
    let mut story = ""
    let mut suggestions = ""
    let mut priority = ""
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
        if @work.task_field(task, "id") == "task-1" {
          stage = @work.task_field(task, "stage")
          description = @work.task_field(task, "description")
          story = @work.task_field(task, "user_story")
          suggestions = @work.task_field(task, "implementation_suggestions")
          priority = @work.task_field(task, "priority")
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
    assert_true(story.contains("As a user"))
    assert_eq(suggestions, "Start with the clarified scope")
    assert_eq(priority, "high")
  })
}

///|
async test "ticket run uses the pinned model instead of the current active model" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  let default_model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("default model result"),
    ),
  ])
  let pinned_model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("pinned model result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("pinned model result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("pinned model result"),
    ),
  ])
  let router = @llm.RouterModelPort(
    slots=[
      subagent_test_slot("test/default", default_model),
      subagent_test_slot("test/pinned", pinned_model),
    ],
    default_slot_id="test/default",
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
      "title": "Pinned model ticket",
      "description": "Use the pinned model",
      "priority": "normal",
      "definition_of_done": ["Evidence"],
      "dependencies": [],
      "user_story": "As a user, I want this ticket, so that it delivers value.",
      "implementation_suggestions": "Start with the acceptance criteria.",
    }
    ignore(
      board.wire_command(
        @board_protocol.encode_client_frame(
          @board_protocol.Command({
            command_id: "pin-create",
            name: "board.task.create",
            expected_revision: 0L,
            args: create,
          }),
        ),
      ),
    )
    ignore(
      board.wire_command(
        @board_protocol.encode_client_frame(
          @board_protocol.Command({
            command_id: "pin-refining",
            name: "board.task.move",
            expected_revision: 1L,
            args: { "id": "task-1", "to": "refining" },
          }),
        ),
      ),
    )
    ignore(
      board.wire_command(
        @board_protocol.encode_client_frame(
          @board_protocol.Command({
            command_id: "pin-ready",
            name: "board.task.move",
            expected_revision: 2L,
            args: { "id": "task-1", "to": "ready" },
          }),
        ),
      ),
    )
    match
      tickets.set_model("task-1", Some({ slot: "test/pinned", effort: None, })) {
      Ok(_) => ()
      Err(error) => fail("ticket set model failed: " + error)
    }
    match
      tickets.set_model("task-1", Some({ slot: "test/missing", effort: None, })) {
      Ok(_) => fail("missing slot must be rejected")
      Err(error) =>
        assert_true(error.contains("not in the current model catalog"))
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
        if @work.task_field(task, "id") == "task-1" {
          stage = @work.task_field(task, "stage")
        }
      }
      if stage == "review" {
        break
      }
      @async.sleep(20)
    }
    assert_eq(stage, "review")
    let state = tickets.state_json().stringify()
    assert_true(state.contains("pinned model result"))
    assert_false(state.contains("default model result"))
  })
}

///|
/// Submit one Board command from a test and fail on transport error or
/// rejection, keeping the retry fixtures readable.
async fn accept_board_command(
  board : @board.BoardWorkflows,
  command_id : String,
  name : String,
  expected_revision : Int64,
  args : Json,
) -> Unit {
  let encoded = match
    board.wire_command(
      @board_protocol.encode_client_frame(
        @board_protocol.Command({ command_id, name, expected_revision, args, }),
      ),
    ) {
    Ok(encoded) => encoded
    Err(error) => fail("board command failed: " + error.code())
  }
  match @board_protocol.decode_server_frame(encoded) {
    Ok(@board_protocol.CommandResult(result)) =>
      if !result.accepted {
        fail("board command was rejected: " + command_id)
      }
    _ => fail("board command did not return a result")
  }
}

///|
/// Poll the authoritative Board snapshot until one ticket reaches `stage`,
/// then return the last stage observed.
async fn wait_ticket_stage(
  board : @board.BoardWorkflows,
  task_id : String,
  stage : String,
) -> String {
  let mut current = ""
  for _ in 0..<150 {
    let snapshot = match
      @board_protocol.decode_server_frame(
        match board.wire_snapshot() {
          Ok(frame) => frame
          Err(error) => fail("snapshot failed: " + error.code())
        },
      ) {
      Ok(@board_protocol.Snapshot(snapshot)) => snapshot
      _ => fail("snapshot was invalid")
    }
    let tasks = match snapshot.payload {
      Object(payload) =>
        match payload.get("board") {
          Some(Object(board)) =>
            match board.get("tasks") {
              Some(Array(tasks)) => tasks
              _ => fail("snapshot has no tasks")
            }
          _ => fail("snapshot has no board")
        }
      _ => fail("snapshot payload is not an object")
    }
    for task in tasks {
      if @work.task_field(task, "id") == task_id {
        current = @work.task_field(task, "stage")
      }
    }
    if current == stage {
      return current
    }
    @async.sleep(20)
  }
  current
}

///|
/// The session id of the ticket runtime's current run for one task, or "".
fn ticket_run_session(tickets : TicketRuntime, task_id : String) -> String {
  match tickets.run_for(task_id) {
    Some(run) => run.session_id
    None => ""
  }
}

///|
/// The status of the ticket runtime's current run for one task, or "".
fn ticket_run_status(tickets : TicketRuntime, task_id : String) -> String {
  match tickets.run_for(task_id) {
    Some(run) => run.status
    None => ""
  }
}

///|
/// The result text of the ticket runtime's current run for one task, or "".
fn ticket_run_result(tickets : TicketRuntime, task_id : String) -> String {
  match tickets.run_for(task_id) {
    Some(run) =>
      match run.result {
        Some(result) => result
        None => ""
      }
    None => ""
  }
}

///|
/// Poll until the ticket runtime parked one question and return its id.
async fn wait_ticket_question(tickets : TicketRuntime) -> String {
  for _ in 0..<200 {
    let ids : Array[String] = []
    for id in tickets.questions.questions.keys() {
      ids.push(id)
    }
    if ids.length() > 0 {
      return ids[0]
    }
    @async.sleep(10)
  }
  ""
}

///|
async test "ticket retry from review starts a fresh child session" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  // One attempt is RD + SET (racing) and then TE; the retry repeats all three.
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("first attempt result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("first attempt result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("first attempt verification result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("retry attempt result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("retry attempt result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("retry attempt verification result"),
    ),
  ])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/retry-review", model)],
    default_slot_id="test/retry-review",
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
      "title": "Retry from review",
      "description": "Do the work twice",
      "priority": "normal",
      "definition_of_done": ["Evidence"],
      "dependencies": [],
      "user_story": "As a user, I want this ticket, so that it delivers value.",
      "implementation_suggestions": "Start with the acceptance criteria.",
    }
    accept_board_command(
      board, "retry-review-create", "board.task.create", 0L, create,
    )
    accept_board_command(
      board,
      "retry-review-refining",
      "board.task.move",
      1L,
      { "id": "task-1", "to": "refining" },
    )
    accept_board_command(board, "retry-review-ready", "board.task.move", 2L, {
      "id": "task-1",
      "to": "ready",
    })
    match tickets.run("task-1") {
      Ok(_) => ()
      Err(error) => fail("ticket run failed: " + error)
    }
    assert_eq(wait_ticket_stage(board, "task-1", "review"), "review")
    let first_session = ticket_run_session(tickets, "task-1")
    assert_true(first_session != "")
    assert_eq(ticket_run_status(tickets, "task-1"), "review")
    // Review is retryable: the ticket moves back to Ready and fresh RD/SET/TE
    // runs start instead of resuming the completed ones.
    let retried = match tickets.retry("task-1") {
      Ok(state) => state
      Err(error) => fail("ticket retry failed: " + error)
    }
    let retry_session = ticket_run_session(tickets, "task-1")
    assert_eq(ticket_run_status(tickets, "task-1"), "running")
    assert_true(retried.stringify().contains(retry_session))
    assert_eq(wait_ticket_stage(board, "task-1", "review"), "review")
    // The durable session id is stable per ticket role; retry clears the
    // transcripts and starts fresh runs under the same ids, so identity is not
    // the proof that a completed session was resumed.
    assert_eq(ticket_run_session(tickets, "task-1"), first_session)
    assert_true(
      tickets.state_json().stringify().contains("retry attempt result"),
    )
    assert_eq(ticket_run_status(tickets, "task-1"), "review")
  })
}

///|
async test "ticket retry from suspended starts a fresh child session" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  // A retry starts RD and SET together and TE after both, so one attempt
  // needs three stops; the first two are interchangeable.
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("retried after suspension"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("retried after suspension"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("retried after suspension, verification passed"),
    ),
  ])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/retry-suspended", model)],
    default_slot_id="test/retry-suspended",
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
      "title": "Retry from suspended",
      "description": "Resume the parked ticket",
      "priority": "normal",
      "definition_of_done": ["Evidence"],
      "dependencies": [],
      "user_story": "As a user, I want this ticket, so that it delivers value.",
      "implementation_suggestions": "Start with the acceptance criteria.",
    }
    accept_board_command(
      board, "retry-suspended-create", "board.task.create", 0L, create,
    )
    accept_board_command(
      board,
      "retry-suspended-refining",
      "board.task.move",
      1L,
      { "id": "task-1", "to": "refining" },
    )
    accept_board_command(
      board,
      "retry-suspended-ready",
      "board.task.move",
      2L,
      { "id": "task-1", "to": "ready" },
    )
    accept_board_command(board, "retry-suspended-park", "board.task.move", 3L, {
      "id": "task-1",
      "to": "suspended",
    })
    let retried = match tickets.retry("task-1") {
      Ok(state) => state
      Err(error) => fail("ticket retry failed: " + error)
    }
    let retry_session = ticket_run_session(tickets, "task-1")
    assert_true(retry_session != "")
    assert_eq(ticket_run_status(tickets, "task-1"), "running")
    assert_true(retried.stringify().contains(retry_session))
    assert_eq(wait_ticket_stage(board, "task-1", "review"), "review")
    assert_true(
      tickets.state_json().stringify().contains("retried after suspension"),
    )
    assert_eq(ticket_run_status(tickets, "task-1"), "review")
  })
}

///|
async test "ticket retry is rejected while the ticket is running" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  // The question parks the worker inside its turn, so the run is genuinely in
  // flight while retry is attempted.
  // RD and SET run together, so one of them parks on the question while the
  // other stops; the parked one continues after the answer and TE verifies.
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_tool_call_response(
        "ask_question_child",
        "call-retry-running",
        { "question": "Which API should the worker use?" },
      ),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("result from the worker that did not ask"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("answered worker result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("verification after the answer"),
    ),
  ])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/retry-running", model)],
    default_slot_id="test/retry-running",
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
      // The worker parks on ask_question_child, which is an unknown tool name
      // to the permission gate; Yolo keeps this test about retry admission.
      parent_mode=() => @permission.Yolo,
      approval=None,
      ctx~,
      group~,
    )
    let create : Json = {
      "id": "task-1",
      "title": "Retry while running",
      "description": "Must not start a second worker",
      "priority": "normal",
      "definition_of_done": ["Evidence"],
      "dependencies": [],
      "user_story": "As a user, I want this ticket, so that it delivers value.",
      "implementation_suggestions": "Start with the acceptance criteria.",
    }
    accept_board_command(
      board, "retry-running-create", "board.task.create", 0L, create,
    )
    accept_board_command(
      board,
      "retry-running-refining",
      "board.task.move",
      1L,
      { "id": "task-1", "to": "refining" },
    )
    accept_board_command(board, "retry-running-ready", "board.task.move", 2L, {
      "id": "task-1",
      "to": "ready",
    })
    match tickets.run("task-1") {
      Ok(_) => ()
      Err(error) => fail("ticket run failed: " + error)
    }
    let question_id = wait_ticket_question(tickets)
    if question_id == "" {
      fail(
        "ticket question was not parked: " +
        tickets.state_json().stringify() +
        " (stage " +
        wait_ticket_stage(board, "task-1", "review") +
        ")",
      )
    }
    let running_session = ticket_run_session(tickets, "task-1")
    assert_eq(ticket_run_status(tickets, "task-1"), "running")
    match tickets.retry("task-1") {
      Ok(_) => fail("retry must be rejected while the ticket is running")
      Err(error) => assert_true(error.contains("already running"))
    }
    // Rejection is a no-op: same run, same session, Board still Running.
    assert_eq(ticket_run_session(tickets, "task-1"), running_session)
    assert_eq(ticket_run_status(tickets, "task-1"), "running")
    assert_eq(wait_ticket_stage(board, "task-1", "running"), "running")
    match
      tickets.questions.answer(
        question_id,
        @posoco.UiResponse::Text("Use the public API"),
        "product_owner",
      ) {
      Ok(_) => ()
      Err(error) => fail("answering the ticket question failed: " + error)
    }
    assert_eq(wait_ticket_stage(board, "task-1", "review"), "review")
    assert_true(
      tickets.state_json().stringify().contains("answered worker result"),
    )
  })
}

///|
async test "ticket retry is rejected from a stage that is not retryable" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  let model = @posoco.ScriptedModel([])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/retry-invalid", model)],
    default_slot_id="test/retry-invalid",
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
      "title": "Retry from backlog",
      "description": "Not shaped yet",
      "priority": "normal",
      "definition_of_done": [],
      "dependencies": [],
      "user_story": "As a user, I want this ticket, so that it delivers value.",
      "implementation_suggestions": "Start with the acceptance criteria.",
    }
    accept_board_command(
      board, "retry-invalid-create", "board.task.create", 0L, create,
    )
    match tickets.retry("task-1") {
      Ok(_) => fail("retry must be rejected before the ticket can run")
      Err(error) => assert_true(error.contains("Ready, Verification, Review"))
    }
    // Nothing started and the Board stage did not move.
    assert_true(tickets.run_for("task-1") is None)
    assert_eq(wait_ticket_stage(board, "task-1", "created"), "created")
  })
}

///|
async test "ticket resume continues the durable child session" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  // One attempt is RD + SET (racing) and then TE; resuming continues the same
  // three durable sessions, so it needs three more stops.
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("first durable result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("first durable result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("first durable verification result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("resumed result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("resumed result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("resumed result, verification passed"),
    ),
  ])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/resume", model)],
    default_slot_id="test/resume",
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
      session_root=Some(directory + "/ticket-sessions"),
    )
    let create : Json = {
      "id": "task-1",
      "title": "Resume durable work",
      "description": "Keep the transcript",
      "priority": "normal",
      "definition_of_done": ["Evidence"],
      "dependencies": [],
      "user_story": "As a user, I want this ticket, so that it delivers value.",
      "implementation_suggestions": "Start with the acceptance criteria.",
    }
    accept_board_command(
      board, "resume-create", "board.task.create", 0L, create,
    )
    accept_board_command(board, "resume-refining", "board.task.move", 1L, {
      "id": "task-1",
      "to": "refining",
    })
    accept_board_command(board, "resume-ready", "board.task.move", 2L, {
      "id": "task-1",
      "to": "ready",
    })
    match tickets.run("task-1") {
      Ok(_) => ()
      Err(error) => fail("ticket run failed: " + error)
    }
    assert_eq(wait_ticket_stage(board, "task-1", "review"), "review")
    let first_session = ticket_run_session(tickets, "task-1")
    assert_true(first_session != "")
    match tickets.move_task("task-1", "suspended") {
      Ok(_) => ()
      Err(error) => fail("could not park the ticket: " + error)
    }
    tickets.dismiss("task-1")
    tickets.reconcile_interrupted() catch {
      error => fail(error.to_string())
    }
    assert_true(tickets.state_json().stringify().contains("interrupted"))
    match tickets.resume_ticket("task-1") {
      Ok(_) => ()
      Err(error) => fail("ticket resume failed: " + error)
    }
    assert_eq(wait_ticket_stage(board, "task-1", "review"), "review")
    // The durable session ids are stable per ticket role; resume continues the
    // recorded sessions instead of minting new ones.
    assert_eq(ticket_run_session(tickets, "task-1"), first_session)
    assert_true(tickets.state_json().stringify().contains("resumed result"))
  })
}

///|
/// The authoritative `board` object of the current snapshot: `tasks` and
/// `attempts` come from one read, so a test never compares across a commit.
async fn board_object_now(board : @board.BoardWorkflows) -> Map[String, Json] {
  let snapshot = match
    @board_protocol.decode_server_frame(
      match board.wire_snapshot() {
        Ok(frame) => frame
        Err(error) => fail("snapshot failed: " + error.code())
      },
    ) {
    Ok(@board_protocol.Snapshot(snapshot)) => snapshot
    _ => fail("snapshot was invalid")
  }
  match snapshot.payload {
    Object(payload) =>
      match payload.get("board") {
        Some(Object(board)) => board
        _ => fail("snapshot has no board")
      }
    _ => fail("snapshot payload is not an object")
  }
}

///|
/// The authoritative Board revision right now. A test that queues or starts an
/// attempt must not hardcode how many revisions the earlier run consumed.
async fn board_revision_now(board : @board.BoardWorkflows) -> Int64 {
  let snapshot = match
    @board_protocol.decode_server_frame(
      match board.wire_snapshot() {
        Ok(frame) => frame
        Err(error) => fail("snapshot failed: " + error.code())
      },
    ) {
    Ok(@board_protocol.Snapshot(snapshot)) => snapshot
    _ => fail("snapshot was invalid")
  }
  snapshot.board_revision
}

///|
/// One string field of one task in the authoritative Board snapshot, or "".
async fn snapshot_task_text(
  board : @board.BoardWorkflows,
  task_id : String,
  key : String,
) -> String {
  let board_object = board_object_now(board)
  let tasks = match board_object.get("tasks") {
    Some(Array(tasks)) => tasks
    _ => fail("snapshot has no tasks")
  }
  for task in tasks {
    if @work.task_field(task, "id") == task_id {
      return @work.task_field(task, key)
    }
  }
  ""
}

///|
/// One string field of one attempt in the authoritative Board snapshot, or "".
async fn snapshot_attempt_text(
  board : @board.BoardWorkflows,
  attempt_id : String,
  key : String,
) -> String {
  let board_object = board_object_now(board)
  let attempts = match board_object.get("attempts") {
    Some(Array(attempts)) => attempts
    _ => fail("snapshot has no attempts")
  }
  for attempt in attempts {
    if @work.task_field(attempt, "id") == attempt_id {
      return @work.task_field(attempt, key)
    }
  }
  ""
}

///|
/// Every user-authored text block of one scripted model call, joined with
/// newlines. The one user message a ticket run sends is its worker prompt.
fn model_user_text(model : @posoco.ScriptedModel, call : Int32) -> String {
  let mut out = ""
  if call >= model.received_messages.length() {
    return out
  }
  for message in model.received_messages[call] {
    match message {
      @posoco.Message::UserMessage(content~) =>
        for block in content {
          match block {
            @posoco.Content::Text(value) => out = out + value + "\n"
            _ => ()
          }
        }
      _ => ()
    }
  }
  out
}

///|
/// Queue one Review attempt for the ticket and start it, so the ticket is
/// genuinely under review by an attempt the host can address.
async fn start_review_attempt(
  board : @board.BoardWorkflows,
  task_id : String,
  attempt_id : String,
) -> Unit {
  let queued = board_revision_now(board)
  accept_board_command(
    board,
    attempt_id + "-queue",
    "board.attempt.queue",
    queued,
    { "id": attempt_id, "task_id": task_id, "kind": "review" },
  )
  accept_board_command(
    board,
    attempt_id + "-start",
    "board.attempt.start",
    queued + 1L,
    { "id": attempt_id },
  )
}

///|
async test "ticket request changes records the feedback, returns the ticket to Ready and starts a fresh run" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  // One attempt is RD + SET (racing) and then TE; requesting changes repeats
  // all three, so the second attempt needs its own three stops.
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("first attempt result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("first attempt result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("first attempt verification result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("revised attempt result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("revised attempt result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("revised attempt verification result"),
    ),
  ])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/request-changes", model)],
    default_slot_id="test/request-changes",
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
      "title": "Review me",
      "description": "Do the work",
      "priority": "normal",
      "definition_of_done": ["Evidence"],
      "dependencies": [],
      "user_story": "As a user, I want this ticket, so that it delivers value.",
      "implementation_suggestions": "Start with the acceptance criteria.",
    }
    accept_board_command(board, "rc-create", "board.task.create", 0L, create)
    accept_board_command(board, "rc-refining", "board.task.move", 1L, {
      "id": "task-1",
      "to": "refining",
    })
    accept_board_command(board, "rc-ready", "board.task.move", 2L, {
      "id": "task-1",
      "to": "ready",
    })
    match tickets.run("task-1") {
      Ok(_) => ()
      Err(error) => fail("ticket run failed: " + error)
    }
    assert_eq(wait_ticket_stage(board, "task-1", "review"), "review")
    start_review_attempt(board, "task-1", "attempt-review-1")
    let state = match
      tickets.request_changes("task-1", "  Add the missing regression test.  ") {
      Ok(state) => state
      Err(error) => fail("request changes failed: " + error)
    }
    // A fresh worker is running. `run` refuses a ticket that is not Ready, so
    // this run also proves the Board moved Review -> Ready and that the host
    // requested changes before starting anything.
    assert_eq(ticket_run_status(tickets, "task-1"), "running")
    assert_true(state.stringify().contains("running"))
    // The Board recorded the decision on the attempt and the trimmed
    // feedback on the ticket.
    assert_eq(
      snapshot_attempt_text(board, "attempt-review-1", "review"),
      "changes_requested",
    )
    assert_eq(
      snapshot_task_text(board, "task-1", "review_feedback"),
      "Add the missing regression test.",
    )
    assert_eq(wait_ticket_stage(board, "task-1", "review"), "review")
    // Request changes starts a new attempt instead of resuming the reviewed
    // one: the run the drawer reads first carries the second worker's result
    // and none of the first. Every role of the reviewed attempt keeps its own
    // run in the host log, so this holds for the current run, not the whole
    // state.
    let ticket_state = tickets.state_json().stringify()
    assert_eq(model.call_count(), 6)
    assert_true(ticket_state.contains("revised attempt verification result"))
    assert_true(
      ticket_run_result(tickets, "task-1").contains(
        "revised attempt verification result",
      ),
    )
    assert_false(
      ticket_run_result(tickets, "task-1").contains(
        "first attempt verification result",
      ),
    )
    assert_eq(ticket_run_status(tickets, "task-1"), "review")
  })
}

///|
async test "ticket request changes rejects empty feedback and a ticket without a running review attempt" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  // The first attempt runs RD and SET together and TE after both; the rejected
  // request changes must not start a fourth call.
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("first attempt result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("first attempt result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("first attempt verification result"),
    ),
  ])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/request-changes-reject", model)],
    default_slot_id="test/request-changes-reject",
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
    // task-1 is under review by a started Review attempt; task-2 is under
    // review with no attempt at all, so there is nothing to address.
    let reviewed : Json = {
      "id": "task-1",
      "title": "Reviewed with an attempt",
      "description": "Do the work",
      "priority": "normal",
      "definition_of_done": ["Evidence"],
      "dependencies": [],
      "user_story": "As a user, I want this ticket, so that it delivers value.",
      "implementation_suggestions": "Start with the acceptance criteria.",
    }
    accept_board_command(
      board, "rc-reject-create-1", "board.task.create", 0L, reviewed,
    )
    let refining = board_revision_now(board)
    accept_board_command(
      board,
      "rc-reject-refining-1",
      "board.task.move",
      refining,
      { "id": "task-1", "to": "refining" },
    )
    accept_board_command(
      board,
      "rc-reject-ready-1",
      "board.task.move",
      refining + 1L,
      { "id": "task-1", "to": "ready" },
    )
    match tickets.run("task-1") {
      Ok(_) => ()
      Err(error) => fail("ticket run failed: " + error)
    }
    assert_eq(wait_ticket_stage(board, "task-1", "review"), "review")
    start_review_attempt(board, "task-1", "attempt-review-1")
    let unattempted : Json = {
      "id": "task-2",
      "title": "Reviewed without an attempt",
      "description": "Do the other work",
      "priority": "normal",
      "definition_of_done": ["Evidence"],
      "dependencies": [],
      "user_story": "As a user, I want this ticket, so that it delivers value.",
      "implementation_suggestions": "Start with the acceptance criteria.",
    }
    let created = board_revision_now(board)
    accept_board_command(
      board, "rc-reject-create-2", "board.task.create", created, unattempted,
    )
    accept_board_command(
      board,
      "rc-reject-refining-2",
      "board.task.move",
      created + 1L,
      { "id": "task-2", "to": "refining" },
    )
    accept_board_command(
      board,
      "rc-reject-ready-2",
      "board.task.move",
      created + 2L,
      { "id": "task-2", "to": "ready" },
    )
    accept_board_command(
      board,
      "rc-reject-running-2",
      "board.task.move",
      created + 3L,
      { "id": "task-2", "to": "running" },
    )
    accept_board_command(
      board,
      "rc-reject-review-2",
      "board.task.move",
      created + 4L,
      { "id": "task-2", "to": "review" },
    )
    match tickets.request_changes("task-1", "   ") {
      Ok(_) => fail("blank feedback must be rejected")
      Err(error) => assert_true(error.contains("must not be empty"))
    }
    // Rejection is a no-op: no new run, no new model call, and the ticket is
    // still the one that was under review.
    assert_eq(ticket_run_status(tickets, "task-1"), "review")
    assert_eq(snapshot_task_text(board, "task-1", "stage"), "review")
    // RD, SET and TE each called the model once for the only attempt.
    assert_eq(model.call_count(), 3)
    match tickets.request_changes("task-2", "Tighten the scope.") {
      Ok(_) =>
        fail("a ticket without a running review attempt must be rejected")
      Err(error) => assert_true(error.contains("no running review attempt"))
    }
    assert_true(tickets.run_for("task-2") is None)
    assert_eq(snapshot_task_text(board, "task-2", "stage"), "review")
    assert_eq(model.call_count(), 3)
  })
}

///|
async test "ticket worker prompt carries the reviewer feedback on the new attempt" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  // One attempt is RD + SET (racing) and then TE; the follow-up attempt after
  // the feedback needs its own three stops.
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("first attempt result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("first attempt result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("first attempt verification result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("revised attempt result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("revised attempt result"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("revised attempt verification result"),
    ),
  ])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/request-changes-prompt", model)],
    default_slot_id="test/request-changes-prompt",
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
      "title": "Review me",
      "description": "Do the work",
      "priority": "normal",
      "definition_of_done": ["Evidence"],
      "dependencies": [],
      "user_story": "As a user, I want this ticket, so that it delivers value.",
      "implementation_suggestions": "Start with the acceptance criteria.",
    }
    accept_board_command(
      board, "rc-prompt-create", "board.task.create", 0L, create,
    )
    accept_board_command(board, "rc-prompt-refining", "board.task.move", 1L, {
      "id": "task-1",
      "to": "refining",
    })
    accept_board_command(board, "rc-prompt-ready", "board.task.move", 2L, {
      "id": "task-1",
      "to": "ready",
    })
    match tickets.run("task-1") {
      Ok(_) => ()
      Err(error) => fail("ticket run failed: " + error)
    }
    assert_eq(wait_ticket_stage(board, "task-1", "review"), "review")
    start_review_attempt(board, "task-1", "attempt-review-1")
    // The first attempt is ordinary work: none of its three workers saw
    // reviewer feedback.
    assert_false(
      model_user_text(model, 0).contains("Add the missing regression test."),
    )
    assert_false(
      model_user_text(model, 1).contains("Add the missing regression test."),
    )
    assert_false(
      model_user_text(model, 2).contains("Add the missing regression test."),
    )
    match
      tickets.request_changes("task-1", "Add the missing regression test.") {
      Ok(_) => ()
      Err(error) => fail("request changes failed: " + error)
    }
    assert_eq(wait_ticket_stage(board, "task-1", "review"), "review")
    assert_eq(model.call_count(), 6)
    // The follow-up attempt opens with RD and SET, both carrying the feedback.
    let prompt = model_user_text(model, 3)
    assert_true(prompt.contains("Reviewer feedback"))
    assert_true(prompt.contains("Add the missing regression test."))
    assert_true(prompt.contains("must address it"))
    // The prompt is still the ticket worker contract.
    assert_true(prompt.contains("Work on this Board ticket as "))
    assert_true(prompt.contains("Definition of done:"))
    assert_true(
      tickets.state_json().stringify().contains("revised attempt result"),
    )
  })
}

///|
/// A host endpoint that only records what the worker reporting tools forwarded.
struct TicketTestReportEndpoint {
  progress : Array[(String, String)]
  mut report : Json?
}

///|
fn TicketTestReportEndpoint::TicketTestReportEndpoint() -> TicketTestReportEndpoint {
  { progress: [], report: None, }
}

///|
impl TicketReportEndpoint for TicketTestReportEndpoint with fn report_progress(
  self,
  kind,
  message,
) -> Unit {
  self.progress.push((kind, message))
}

///|
impl TicketReportEndpoint for TicketTestReportEndpoint with fn submit_work_report(
  self,
  report,
) -> Result[Unit, String] {
  self.report = Some(report)
  Ok(())
}

///|
/// One tool call context for the reporting tools, the way the runtime hands it
/// over: the name is the model's choice, the ticket binding is never in it.
fn ticket_report_call(
  name : String,
  arguments : Json,
) -> @posoco.ToolCallContext {
  @posoco.ToolCallContext(
    effect_id=@kernel.EffectId::{ value: 11, },
    call_id=@posoco.CallId::unchecked("call-" + name),
    name=@posoco.ToolName::unchecked(name),
    arguments~,
    register_cancel=fn(_ : &@posoco.ToolCancellable) { () },
  )
}

///|
/// One string field of a projected host or Board JSON object, or "".
fn report_json_text(value : Json, key : String) -> String {
  match value {
    Object(fields) =>
      match fields.get(key) {
        Some(String(text)) => text
        _ => ""
      }
    _ => ""
  }
}

///|
/// One array field of a projected JSON object, or an empty array.
fn report_json_array(value : Json, key : String) -> Array[Json] {
  match value {
    Object(fields) =>
      match fields.get(key) {
        Some(Array(values)) => values
        _ => []
      }
    _ => []
  }
}

///|
/// The string entries of one array field of a Board review report.
fn review_strings(review : Json, key : String) -> Array[String] {
  report_json_array(review, key).filter_map(value => {
    match value {
      String(text) => Some(text)
      _ => None
    }
  })
}

///|
/// The durable review report the Board currently holds for one ticket.
async fn snapshot_task_review(
  board : @board.BoardWorkflows,
  task_id : String,
) -> Json? {
  let tasks = match board_object_now(board).get("tasks") {
    Some(Array(tasks)) => tasks
    _ => fail("snapshot has no tasks")
  }
  for task in tasks {
    if @work.task_field(task, "id") == task_id {
      return task_review(task)
    }
  }
  None
}

///|
async test "ticket report tools expose exactly the two reporting tools" {
  let endpoint = TicketTestReportEndpoint::TicketTestReportEndpoint()
  let tools = TicketReportTools::TicketReportTools(endpoint~)
  let defs = @posoco.ToolProvider::list_tools(tools)
  assert_eq(defs.length(), 2)
  assert_eq(defs[0].name.to_string(), "report_progress")
  assert_eq(defs[1].name.to_string(), "submit_work_report")
  // Neither may interleave with other calls, and neither is an Exclusive
  // barrier: progress is cheap and a report is a last write.
  for def in defs {
    assert_true(def.policy is @posoco.ExecutionPolicy::Sequential)
  }
  let manifest = @posoco.Extension::manifest(tools)
  assert_eq(manifest.id, "cetas_ticket_report")
  assert_eq(manifest.tools.length(), 1)
  // An unknown name is a hard error, never a silent no-op.
  let outcome : Result[@posoco.ToolOutcome, @posoco.RuntimeError] = Ok(
    @posoco.ToolProvider::execute(
      tools,
      ticket_report_call("board_task_move", Json::object({})),
    ),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Err(@posoco.RuntimeError::UnknownTool(message)) =>
      assert_true(message.contains("unknown tool 'board_task_move'"))
    _ => fail("an unknown reporting tool name must be rejected")
  }
}

///|
async test "ticket report tools appear only for children with a report endpoint" {
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("plain child")),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("reporting child"),
    ),
  ])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/report-face", model)],
    default_slot_id="test/report-face",
  )
  let fs = @workspace.JsWorkspaceFs()
  let plain = CetasChildComposer::CetasChildComposer(
    parent_manager=Providers(router),
    parent_mode=fn() { @permission.ReadOnly },
    context_fs=fs,
    feature_fs=fs,
    cwd=".",
    home=".",
  )
  let plain_child = @subagent.ChildComposer::compose(
    plain,
    subagent_test_spec("test/report-face", Some(["read"])),
  )
  ignore(
    plain_child.run_scoped(async fn(agent) {
      agent.run_turn(@posoco.tk_user_msg("go"), "subagent-test")
    }),
  )
  let plain_names = model.received_tools[0].map(fn(def) { def.name.to_string() })
  assert_eq(plain_names, ["read"])
  // The ticket face exists only because the host injected an endpoint.
  let endpoint = TicketTestReportEndpoint::TicketTestReportEndpoint()
  let reporting = CetasChildComposer::CetasChildComposer(
    parent_manager=Providers(router),
    parent_mode=fn() { @permission.ReadOnly },
    reporting=Some(endpoint as &TicketReportEndpoint),
    context_fs=fs,
    feature_fs=fs,
    cwd=".",
    home=".",
  )
  let reporting_child = @subagent.ChildComposer::compose(reporting, {
    ..subagent_test_spec("test/report-face", Some(["read"])),
    session_id: "subagent-reporting",
  })
  ignore(
    reporting_child.run_scoped(async fn(agent) {
      agent.run_turn(@posoco.tk_user_msg("go"), "subagent-reporting")
    }),
  )
  let names = model.received_tools[1].map(fn(def) { def.name.to_string() })
  assert_eq(names, ["read", "report_progress", "submit_work_report"])
}

///|
async test "ticket report progress trims, defaults and validates its message" {
  let endpoint = TicketTestReportEndpoint::TicketTestReportEndpoint()
  let tools = TicketReportTools::TicketReportTools(endpoint~)
  let recorded = @posoco.ToolProvider::execute(
    tools,
    ticket_report_call(
      "report_progress",
      Json::object({
        "message": Json::string("  Read the ticket and started  "),
      }),
    ),
  )
  match recorded {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_eq(content, "Progress recorded.")
    other => fail("report_progress must succeed: \{other}")
  }
  assert_eq(endpoint.progress.length(), 1)
  // The kind defaults to normal and the message is trimmed before storage.
  assert_eq(endpoint.progress[0].0, "normal")
  assert_eq(endpoint.progress[0].1, "Read the ticket and started")
  let attention = @posoco.ToolProvider::execute(
    tools,
    ticket_report_call(
      "report_progress",
      Json::object({
        "kind": Json::string("attention"),
        "message": Json::string("Investigating one failure; work continues"),
      }),
    ),
  )
  match attention {
    @posoco.ToolOutcome::Success(..) => ()
    other => fail("a declared progress kind must be accepted: \{other}")
  }
  assert_eq(endpoint.progress[1].0, "attention")
  let mut long = ""
  for _ in 0..<501 {
    long = long + "x"
  }
  for
    (arguments, expected) in [
      (Json::object({ "message": Json::string("") }), "non-empty"),
      (Json::object({ "message": Json::string("   ") }), "non-empty"),
      (Json::object({ "message": Json::string(long) }), "at most 500"),
      (
        Json::object({
          "kind": Json::string("panic"),
          "message": Json::string("Status"),
        }),
        "kind",
      ),
      (Json::object({ "message": Json::number(1.0) }), "must be a string"),
      (Json::object({}), "required"),
    ] {
    let rejected = @posoco.ToolProvider::execute(
      tools,
      ticket_report_call("report_progress", arguments),
    )
    match rejected {
      @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
        assert_true(content.contains(expected))
      other => fail("invalid progress must fail visibly: \{other}")
    }
  }
  // Nothing invalid was recorded and no question was ever asked.
  assert_eq(endpoint.progress.length(), 2)
}

///|
async test "ticket work report is normalized to the Board review shape" {
  let endpoint = TicketTestReportEndpoint::TicketTestReportEndpoint()
  let tools = TicketReportTools::TicketReportTools(endpoint~)
  let report = Json::object({
    "outcome": Json::string("  Ticket done  "),
    "summary": Json::string("The worker can now report progress and a report"),
    "changes": Json::array([Json::string("lib/ticket_report_tools.mbt")]),
    "verification": Json::array([
      Json::object({
        "kind": Json::string("test"),
        "label": Json::string("moon test lib"),
        "result": Json::string("passed"),
        "detail": Json::string("all ticket tests green"),
      }),
    ]),
    "risks": Json::array([Json::string("Approval-gated tool names")]),
    "notes": Json::array([]),
    "open_questions": Json::array([]),
    "artifacts": Json::array([
      Json::object({
        "kind": Json::string("file"),
        "label": Json::string("ticket_report_tools.mbt"),
        "uri_or_digest": Json::string("file://lib/ticket_report_tools.mbt"),
      }),
    ]),
    "unexpected": Json::string("dropped, never forwarded"),
  })
  let outcome = @posoco.ToolProvider::execute(
    tools,
    ticket_report_call("submit_work_report", report),
  )
  match outcome {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_eq(content, "Work report recorded.")
    other => fail("a valid work report must be recorded: \{other}")
  }
  let stored = match endpoint.report {
    Some(stored) => stored
    None => fail("the report was not forwarded to the host endpoint")
  }
  // Exactly the Board fields survive: the outcome is trimmed and an unknown
  // key cannot reach a strict Board decoder.
  assert_eq(report_json_text(stored, "outcome"), "Ticket done")
  assert_false(stored.stringify().contains("unexpected"))
  assert_eq(review_strings(stored, "changes"), ["lib/ticket_report_tools.mbt"])
  assert_eq(review_strings(stored, "risks"), ["Approval-gated tool names"])
  let verification = report_json_array(stored, "verification")
  assert_eq(verification.length(), 1)
  assert_eq(report_json_text(verification[0], "kind"), "test")
  assert_eq(report_json_text(verification[0], "result"), "passed")
  assert_eq(
    report_json_text(verification[0], "detail"),
    "all ticket tests green",
  )
  let artifacts = report_json_array(stored, "artifacts")
  assert_eq(artifacts.length(), 1)
  assert_eq(
    report_json_text(artifacts[0], "uri_or_digest"),
    "file://lib/ticket_report_tools.mbt",
  )
  // An invalid report is a visible failure, never a silent partial report.
  for
    (arguments, expected) in [
      (
        Json::object({ "summary": Json::string("missing outcome") }),
        "'outcome' is required",
      ),
      (
        Json::object({
          "outcome": Json::string("done"),
          "summary": Json::string("   "),
        }),
        "'summary' must not be empty",
      ),
      (
        Json::object({
          "outcome": Json::string("done"),
          "summary": Json::string("ok"),
          "verification": Json::array([
            Json::object({
              "kind": Json::string("vibes"),
              "label": Json::string("looks right"),
              "result": Json::string("passed"),
              "detail": Json::string(""),
            }),
          ]),
        }),
        "'verification.kind' must be one of",
      ),
      (
        Json::object({
          "outcome": Json::string("done"),
          "summary": Json::string("ok"),
          "artifacts": Json::array([
            Json::object({
              "kind": Json::string("file"),
              "label": Json::string("report"),
              "uri_or_digest": Json::string(" "),
            }),
          ]),
        }),
        "'artifacts.uri_or_digest' must not be empty",
      ),
      (
        Json::object({
          "outcome": Json::string("done"),
          "summary": Json::string("ok"),
          "changes": Json::array([Json::number(1.0)]),
        }),
        "'changes' entry must be a string",
      ),
    ] {
    let rejected = @posoco.ToolProvider::execute(
      tools,
      ticket_report_call("submit_work_report", arguments),
    )
    match rejected {
      @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
        assert_true(content.contains(expected))
      other => fail("an invalid work report must fail visibly: \{other}")
    }
  }
  // The last rejected report did not overwrite the recorded one.
  assert_eq(
    report_json_text(endpoint.report.unwrap(), "outcome"),
    "Ticket done",
  )
}

///|
async test "ticket progress state json keeps a bounded per-ticket log" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  let model = @posoco.ScriptedModel([])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/progress-bound", model)],
    default_slot_id="test/progress-bound",
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
    for index in 0..<55 {
      tickets.record_progress("task-1", "normal", "line-" + index.to_string())
    }
    for index in 0..<3 {
      tickets.record_progress(
        "task-2",
        "milestone",
        "other-" + index.to_string(),
      )
    }
    // Blank updates are dropped instead of projected as empty lines.
    tickets.record_progress("task-1", "normal", "   ")
    let entries = match tickets.state_json() {
      Object(fields) =>
        match fields.get("progress") {
          Some(Array(entries)) => entries
          _ => fail("ticket state has no progress array")
        }
      _ => fail("ticket state is not an object")
    }
    let first : Array[Json] = []
    let second : Array[Json] = []
    for entry in entries {
      let task_id = report_json_text(entry, "task_id")
      assert_true(report_json_text(entry, "kind") != "")
      assert_true(report_json_text(entry, "message") != "")
      assert_true(report_json_text(entry, "at_ms") == "")
      // Every projected update carries the full shape, including a timestamp.
      match entry {
        Object(fields) =>
          match fields.get("at_ms") {
            Some(Number(value, ..)) => assert_true(value >= 0.0)
            _ => fail("a progress update has no at_ms")
          }
        _ => fail("a progress update is not an object")
      }
      if task_id == "task-1" {
        first.push(entry)
      } else if task_id == "task-2" {
        second.push(entry)
      }
    }
    // Bounded per ticket, oldest dropped, newest kept.
    assert_eq(first.length(), 50)
    assert_eq(second.length(), 3)
    assert_eq(report_json_text(first[0], "message"), "line-5")
    assert_eq(report_json_text(first[49], "message"), "line-54")
    assert_eq(report_json_text(second[0], "message"), "other-0")
    assert_eq(report_json_text(second[0], "kind"), "milestone")
  })
}

///|
async test "ticket run persists the submitted work report instead of the minimal one" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  // RD and SET only stop; the durable report the Board keeps is TE's, so TE
  // reports progress, submits the structured report and then answers.
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("product change ready for verification"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("independent verification ready"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_tool_call_response("report_progress", "call-progress-1", {
        "kind": "milestone",
        "message": "Read the ticket and planned the change",
      }),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_tool_call_response("submit_work_report", "call-report-1", {
        "outcome": "Ticket done: reporting tools wired",
        "summary": "The worker reported progress and a structured handoff",
        "changes": ["lib/ticket_report_tools.mbt"],
        "verification": [
          {
            "kind": "test",
            "label": "moon test lib",
            "result": "passed",
            "detail": "all ticket tests green",
          },
        ],
        "risks": [],
        "notes": ["Board validation still owns the durable report"],
        "open_questions": [],
        "artifacts": [],
      }),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("worker final answer"),
    ),
  ])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/work-report", model)],
    default_slot_id="test/work-report",
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
      // The reporting tools are not read-class tools; Yolo keeps this test
      // about the report itself instead of ticket approval wiring.
      parent_mode=() => @permission.Yolo,
      approval=None,
      ctx~,
      group~,
    )
    let create : Json = {
      "id": "task-1",
      "title": "Report the work",
      "description": "Use the reporting tools",
      "priority": "normal",
      "definition_of_done": ["Evidence"],
      "dependencies": [],
      "user_story": "As a user, I want this ticket, so that it delivers value.",
      "implementation_suggestions": "Start with the acceptance criteria.",
    }
    accept_board_command(
      board, "report-create", "board.task.create", 0L, create,
    )
    accept_board_command(board, "report-refining", "board.task.move", 1L, {
      "id": "task-1",
      "to": "refining",
    })
    accept_board_command(board, "report-ready", "board.task.move", 2L, {
      "id": "task-1",
      "to": "ready",
    })
    match tickets.run("task-1") {
      Ok(_) => ()
      Err(error) => fail("ticket run failed: " + error)
    }
    assert_eq(wait_ticket_stage(board, "task-1", "review"), "review")
    // The worker prompt carries the reporting contract.
    let prompt = model_user_text(model, 0)
    assert_true(prompt.contains("Reporting contract"))
    assert_true(prompt.contains("report_progress"))
    assert_true(prompt.contains("submit_work_report"))
    assert_true(prompt.contains("audience=\"refiner\""))
    let review = match snapshot_task_review(board, "task-1") {
      Some(review) => review
      None => fail("the ticket reached Review without a durable report")
    }
    // The submitted report, not the minimal fallback, is what the Board holds.
    assert_eq(
      review_field(review, "outcome"),
      "Ticket done: reporting tools wired",
    )
    assert_eq(
      review_field(review, "summary"),
      "The worker reported progress and a structured handoff",
    )
    assert_false(
      review_field(review, "summary").contains("worker final answer"),
    )
    assert_eq(review_strings(review, "changes"), ["lib/ticket_report_tools.mbt"])
    assert_eq(review_strings(review, "notes"), [
      "Board validation still owns the durable report",
    ])
    let verification = report_json_array(review, "verification")
    assert_eq(verification.length(), 1)
    assert_eq(report_json_text(verification[0], "kind"), "test")
    assert_eq(report_json_text(verification[0], "result"), "passed")
    assert_eq(report_json_text(verification[0], "label"), "moon test lib")
    assert_eq(wait_ticket_stage(board, "task-1", "review"), "review")
    assert_eq(ticket_run_status(tickets, "task-1"), "review")
    // Progress collected during the run is projected for the drawer.
    assert_true(
      tickets
      .state_json()
      .stringify()
      .contains("Read the ticket and planned the change"),
    )
  })
}

///|
async test "ticket finish fails visibly when the Board rejects the report" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  let model = @posoco.ScriptedModel([])
  let router = @llm.RouterModelPort(
    slots=[subagent_test_slot("test/rejected-report", model)],
    default_slot_id="test/rejected-report",
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
      "title": "Reject my report",
      "description": "The Board is the authority",
      "priority": "normal",
      "definition_of_done": ["Evidence"],
      "dependencies": [],
      "user_story": "As a user, I want this ticket, so that it delivers value.",
      "implementation_suggestions": "Start with the acceptance criteria.",
    }
    accept_board_command(
      board, "reject-create", "board.task.create", 0L, create,
    )
    accept_board_command(board, "reject-refining", "board.task.move", 1L, {
      "id": "task-1",
      "to": "refining",
    })
    accept_board_command(board, "reject-ready", "board.task.move", 2L, {
      "id": "task-1",
      "to": "ready",
    })
    accept_board_command(board, "reject-running", "board.task.move", 3L, {
      "id": "task-1",
      "to": "running",
    })
    // A report the Board's own validation rejects: an empty outcome. The
    // runtime must fail the run instead of falling back to the minimal report.
    let te = tickets.add_run(
      "task-1",
      @work.work_session_id("task-1", "te"),
      "work",
      "te",
    )
    te.report = Some(
      Json::object({
        "outcome": Json::string(""),
        "summary": Json::string("empty outcome"),
        "changes": Json::array([]),
        "verification": Json::array([]),
        "risks": Json::array([]),
        "notes": Json::array([]),
        "open_questions": Json::array([]),
        "artifacts": Json::array([]),
      }),
    )
    tickets.finish_work("task-1", "te", Ok("worker final answer"))
    assert_eq(ticket_run_status(tickets, "task-1"), "failed")
    let error = match tickets.run_for("task-1") {
      Some(run) =>
        match run.error {
          Some(error) => error
          None => fail("a failed run must record why")
        }
      None => fail("the run projection disappeared")
    }
    assert_true(error.contains("review report was not recorded"))
    // Recovery C keeps the ticket in its lane; the failed run is visible and
    // resumable instead of being auto-parked on Suspended.
    assert_eq(snapshot_task_text(board, "task-1", "stage"), "running")
    // Nothing was silently recorded: the ticket has no durable report at all.
    assert_true(snapshot_task_review(board, "task-1") is None)
  })
}

///|
async test "RD-only role plan reaches review without starting SET or TE" {
  let directory = @board_fixtures.temporary_directory()
  defer @board_fixtures.cleanup(directory)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("SEO audit completed."),
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
      "title": "Audit SEO",
      "description": "Audit the current site",
      "priority": "normal",
      "definition_of_done": ["Report"],
      "dependencies": [],
      "user_story": "As a maintainer\nI want an audit\nSo that I know the gaps",
      "implementation_suggestions": "Inspect the built site.",
    }
    match
      board.wire_command(
        @board_protocol.encode_client_frame(
          @board_protocol.Command({
            command_id: "rd-only-create",
            name: "board.task.create",
            expected_revision: 0L,
            args: create,
          }),
        ),
      ) {
      Ok(encoded) =>
        match @board_protocol.decode_server_frame(encoded) {
          Ok(@board_protocol.CommandResult(result)) =>
            assert_true(result.accepted)
          _ => fail("create did not settle")
        }
      Err(error) => fail(error.code())
    }
    match
      board.wire_command(
        @board_protocol.encode_client_frame(
          @board_protocol.Command({
            command_id: "rd-only-roles",
            name: "board.task.set_required_roles",
            expected_revision: 1L,
            args: { "id": "task-1", "roles": ["rd"] },
          }),
        ),
      ) {
      Ok(encoded) =>
        match @board_protocol.decode_server_frame(encoded) {
          Ok(@board_protocol.CommandResult(result)) =>
            assert_true(result.accepted)
          _ => fail("role plan did not settle")
        }
      Err(error) => fail(error.code())
    }
    match
      board.wire_command(
        @board_protocol.encode_client_frame(
          @board_protocol.Command({
            command_id: "rd-only-refining",
            name: "board.task.move",
            expected_revision: 2L,
            args: { "id": "task-1", "to": "refining" },
          }),
        ),
      ) {
      Ok(encoded) =>
        match @board_protocol.decode_server_frame(encoded) {
          Ok(@board_protocol.CommandResult(result)) =>
            assert_true(result.accepted)
          _ => fail("refining move did not settle")
        }
      Err(error) => fail(error.code())
    }
    match
      board.wire_command(
        @board_protocol.encode_client_frame(
          @board_protocol.Command({
            command_id: "rd-only-ready",
            name: "board.task.move",
            expected_revision: 3L,
            args: { "id": "task-1", "to": "ready" },
          }),
        ),
      ) {
      Ok(encoded) =>
        match @board_protocol.decode_server_frame(encoded) {
          Ok(@board_protocol.CommandResult(result)) =>
            assert_true(result.accepted)
          _ => fail("ready move did not settle")
        }
      Err(error) => fail(error.code())
    }
    match tickets.run("task-1") {
      Ok(_) => ()
      Err(error) => fail("RD-only run failed: " + error)
    }
    let mut reached = false
    for _ in 0..<100 {
      match tickets.task_snapshot("task-1") {
        Ok((task, _)) =>
          if @work.task_field(task, "stage") == "review" {
            reached = true
            break
          }
        Err(_) => ()
      }
      @async.sleep(20)
    }
    assert_true(reached)
    assert_eq(tickets.runs_for("task-1").map(run => run.role), ["rd"])
  })
}
