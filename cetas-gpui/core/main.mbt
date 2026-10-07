///|
/// Native GPUI host observer. It projects the same semantic stream that
/// cetas-web consumes, but sends it through the in-process C queue.
struct DesktopObserver {
  mut session_id : String
  mut turn_id : String
  mut turn_no : Int
}

///|
fn DesktopObserver::new(session_id : String) -> DesktopObserver {
  { session_id, turn_id: "", turn_no: 0, }
}

///|
fn DesktopObserver::emit(
  self : DesktopObserver,
  event_type : String,
  extra? : Array[(String, Json)] = [],
) -> Unit {
  bridge_emit(event_type, self.session_id, self.turn_id, extra~)
}

///|
impl @posoco.Observer for DesktopObserver with fn on_event(
  self,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::TurnStarted => self.emit("turn.started")
    @posoco.TurnEvent::StreamChunkReceived(chunk~) =>
      match chunk {
        @posoco.StreamChunk::TextDelta(token~) =>
          self.emit("assistant.text_delta", extra=[
            ("delta", Json::string(token)),
          ])
        @posoco.StreamChunk::ReasoningDelta(token~) =>
          self.emit("assistant.reasoning_delta", extra=[
            ("delta", Json::string(token)),
          ])
        _ => ()
      }
    @posoco.TurnEvent::ToolCallPending(call) =>
      self.emit("tool.started", extra=[
        ("tool_call_id", Json::string(call.call_id.to_string())),
        ("tool_name", Json::string(call.name.to_string())),
        ("arguments", call.arguments),
      ])
    @posoco.TurnEvent::ToolCallSucceeded(call~, content~, ..) =>
      self.emit("tool.completed", extra=[
        ("tool_call_id", Json::string(call.call_id.to_string())),
        ("tool_name", Json::string(call.name.to_string())),
        ("result", Json::string(content)),
        ("is_error", Json::boolean(false)),
      ])
    @posoco.TurnEvent::ToolCallFailed(call~, failure~) => {
      let text = match failure {
        ReportedError(content~, ..) => content
        Runtime(category~, message~) => "\{category}: \{message}"
      }
      self.emit("tool.completed", extra=[
        ("tool_call_id", Json::string(call.call_id.to_string())),
        ("tool_name", Json::string(call.name.to_string())),
        ("result", Json::string(text)),
        ("is_error", Json::boolean(true)),
      ])
    }
    _ => ()
  }
}

///|
impl @posoco.Extension for DesktopObserver with fn extension_id(
  _self : DesktopObserver,
) -> String {
  "cetas_gpui_observer"
}

///|
impl @posoco.Extension for DesktopObserver with fn manifest(
  self : DesktopObserver,
) -> @posoco.ExtensionManifest {
  let manifest = @posoco.ExtensionManifest::default(id="cetas_gpui_observer")
  { ..manifest, observers: [self], }
}

///|
fn command_field(fields : Map[String, Json], name : String) -> String? {
  match fields.get(name) {
    Some(Json::String(value)) => Some(value)
    _ => None
  }
}

///|
async fn run_desktop(
  group : @async.TaskGroup[Unit],
) -> Unit {
  let home = @cetas_core.cetas_home()
  let cwd = @env.current_dir().unwrap_or(".")
  let fs_impl = @workspace.NativeWorkspaceFs()
  let fs : &@workspace.WorkspaceFs = fs_impl
  let warn = async fn(text : String) noraise {
    bridge_emit(
      "runtime.warning",
      "",
      "",
      extra=[("message", Json::string(text))],
    )
  }

  let platform = @cetas_core.build_cetas_platform(
    home~,
    cwd~,
    fs,
    permission_mode=@permission.PermissionMode::WorkspaceWrite,
    mcp_group=Some(group),
    label="cetas-gpui",
    warn~,
  )
  let session_id = @cetas_core.mint_session_id()
  // POC deliberately uses cetas-core directly. The compiled desktop recipe
  // can be layered in after the host/runtime boundary has proven sound.
  let session = @cetas_core.build_cetas_session(
    platform~,
    cwd~,
    label="cetas-gpui",
    warn~,
  )
  let observer = DesktopObserver::new(session_id)
  let tail_exts : Array[&@posoco.Extension] = [
    observer as &@posoco.Extension,
  ]
  let agent = @cetas_core.compose_cetas_agent(
    session~,
    tail_exts~,
    runtime_group=Some(group),
  )
  bridge_emit(
    "session.snapshot",
    session_id,
    "",
    extra=[
      ("model", Json::string(session.router.active_slot_id())),
      ("cwd", Json::string(cwd)),
      ("busy", Json::boolean(false)),
    ],
  )

  while true {
    let raw = bridge_next_command()
    if raw == "" {
      @async.sleep(16)
      continue
    }
    let parsed = @json.parse(raw) catch {
      _ => {
        bridge_emit(
          "protocol.error",
          session_id,
          "",
          extra=[("message", Json::string("invalid desktop command JSON"))],
        )
        continue
      }
    }
    guard parsed is Json::Object(fields) else {
      continue
    }
    let kind = command_field(fields, "type").unwrap_or("")
    if kind == "turn.start" {
      let prompt = command_field(fields, "prompt").unwrap_or("").trim().to_owned()
      if prompt == "" {
        continue
      }
      observer.turn_no += 1
      observer.turn_id = "t-" + observer.turn_no.to_string()
      bridge_emit(
        "turn.accepted",
        session_id,
        observer.turn_id,
        extra=[("prompt", Json::string(prompt))],
      )
      let outcome : Result[String, @posoco.AgentError] = Ok(
        @cetas_core.run_prompt(agent, prompt, session_id),
      ) catch {
        error => Err(error)
      }
      match outcome {
        Ok(text) =>
          bridge_emit(
            "turn.completed",
            session_id,
            observer.turn_id,
            extra=[("text", Json::string(text))],
          )
        Err(error) =>
          bridge_emit(
            "turn.failed",
            session_id,
            observer.turn_id,
            extra=[("message", Json::string(error.to_string()))],
          )
      }
    }
  }
}

///|
async fn main {
  @async.with_task_group(group => {
    run_desktop(group) catch {
      error =>
        bridge_emit(
          "runtime.unavailable",
          "",
          "",
          extra=[("message", Json::string(error.to_string()))],
        )
    }
  })
}
