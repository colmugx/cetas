///|
/// Native terminal UI — nested child runs and non-blocking questions.
///
/// Both surfaces exist only for the native host's realtime projection, so
/// everything here is gated by `ConsoleConfig::native_ui`: the subagent
/// extension is composed only when the projection is opted in, its child
/// events are re-emitted in the native shape only then, and the non-blocking
/// question lifecycle is subscribed only then. The default (web) console
/// composes exactly what it composed before and receives no new frame.
///
/// Child facts are *out of band*: they ride the same sink but never enter the
/// rolling wire log, a per-turn ledger or the parent transcript. A child tool
/// call is therefore impossible to mistake for a parent tool row — the frame
/// type differs, and the ledger never sees it.

// ──────────────────────────────────────────────────────────────────────────
// Child-event normalization
// ──────────────────────────────────────────────────────────────────────────

///|
/// Normalize one child-run `TurnEvent` into the native renderer's shape.
///
/// The parent observer maps the same kernel vocabulary onto `tool.*` /
/// `assistant.*` frames; here the result is nested under `subagent.event.ev`
/// so a host can render a child row with the same field names it already
/// understands. `None` means "nothing to project": the event is a child-local
/// projection fact (context occupancy, child compaction, child operation
/// finalization — the JS oracle drops exactly this set, a child compaction is
/// the child's own progress) or an audit-only node with no renderable payload.
fn native_child_ev_json(event : @posoco.TurnEvent) -> Json? {
  match event {
    @posoco.TurnEvent::TurnStarted =>
      Some(Json::object({ "type": "turn.started" }))
    @posoco.TurnEvent::TurnCompleted =>
      Some(Json::object({ "type": "turn.completed" }))
    @posoco.TurnEvent::TurnFailed(message) =>
      Some(
        Json::object({ "type": "turn.failed", "message": Json::string(message) }),
      )
    @posoco.TurnEvent::StreamChunkReceived(chunk~) =>
      match chunk {
        @posoco.StreamChunk::TextDelta(token~) =>
          Some(
            Json::object({
              "type": "assistant.text_delta",
              "delta": Json::string(token),
            }),
          )
        @posoco.StreamChunk::ReasoningDelta(token~) =>
          Some(
            Json::object({
              "type": "assistant.reasoning_delta",
              "delta": Json::string(token),
            }),
          )
        @posoco.StreamChunk::ToolCallDelta(index~, id~, name~, arguments_delta~) =>
          Some(
            Json::object({
              "type": "tool.args_delta",
              "index": Json::number(index.to_double()),
              "id": native_json_string_opt(id),
              "name": native_json_string_opt(name),
              "delta": native_json_string_opt(arguments_delta),
            }),
          )
        _ => None
      }
    @posoco.TurnEvent::ToolCallPending(call) =>
      Some(
        Json::object({
          "type": "tool.pending",
          "tool_call_id": Json::string(call.call_id.to_string()),
          "tool_name": Json::string(call.name.to_string()),
          "arguments": call.arguments,
        }),
      )
    @posoco.TurnEvent::ToolCallApproved(call~, consent_scope~) =>
      Some(
        Json::object({
          "type": "tool.approved",
          "tool_call_id": Json::string(call.call_id.to_string()),
          "tool_name": Json::string(call.name.to_string()),
          "consent_scope": native_json_string_opt(consent_scope),
        }),
      )
    @posoco.TurnEvent::ToolCallStarted(call~) =>
      Some(
        Json::object({
          "type": "tool.started",
          "tool_call_id": Json::string(call.call_id.to_string()),
          "tool_name": Json::string(call.name.to_string()),
          "arguments": call.arguments,
        }),
      )
    @posoco.TurnEvent::ToolCallSucceeded(
      call~,
      content~,
      structured~,
      attachments~
    ) =>
      Some(
        Json::object({
          "type": "tool.succeeded",
          "tool_call_id": Json::string(call.call_id.to_string()),
          "tool_name": Json::string(call.name.to_string()),
          "result": Json::string(content),
          "is_error": Json::boolean(false),
          "structured": match structured {
            Some(value) => value
            None => Json::null()
          },
          "attachments": Json::array(native_attachment_json(attachments)),
        }),
      )
    @posoco.TurnEvent::ToolCallFailed(call~, failure~) => {
      let (result, failure_kind, category, structured) = match failure {
        ReportedError(content~, structured~) =>
          (content, "reported_error", "", structured)
        Runtime(category~, message~) =>
          ("\{category}: \{message}", "runtime", category, None)
      }
      Some(
        Json::object({
          "type": "tool.failed",
          "tool_call_id": Json::string(call.call_id.to_string()),
          "tool_name": Json::string(call.name.to_string()),
          "result": Json::string(result),
          "is_error": Json::boolean(true),
          "failure_kind": Json::string(failure_kind),
          "error_category": Json::string(category),
          "structured": match structured {
            Some(value) => value
            None => Json::null()
          },
          "attachments": Json::array(native_attachment_json([])),
        }),
      )
    }
    @posoco.TurnEvent::ToolCallRejected(call~, reason~) =>
      Some(
        Json::object({
          "type": "tool.rejected",
          "tool_call_id": Json::string(call.call_id.to_string()),
          "tool_name": Json::string(call.name.to_string()),
          "result": Json::string(reason.to_string()),
          "reason": Json::string(reason.to_string()),
          "is_error": Json::boolean(true),
        }),
      )
    @posoco.TurnEvent::ToolCallAbandoned(call~, reason~) =>
      Some(
        Json::object({
          "type": "tool.abandoned",
          "tool_call_id": Json::string(call.call_id.to_string()),
          "tool_name": Json::string(call.name.to_string()),
          "result": Json::string(reason),
          "reason": Json::string(reason),
          "is_error": Json::boolean(true),
        }),
      )
    @posoco.TurnEvent::ModelResponseReceived(usage~, ..) =>
      match usage {
        Some(usage) =>
          Some(
            Json::object({
              "type": "usage.delta",
              "input_tokens": native_json_int_opt(usage.input_tokens),
              "output_tokens": native_json_int_opt(usage.output_tokens),
              "total_tokens": native_json_int_opt(usage.total_tokens),
              "cached_input_tokens": native_json_int_opt(
                usage.cached_input_tokens,
              ),
            }),
          )
        None => None
      }
    @posoco.TurnEvent::SessionRedirect(from~, to~, ..) =>
      Some(
        Json::object({
          "type": "session.redirect",
          "from": Json::string(from),
          "to": Json::string(to),
        }),
      )
    @posoco.TurnEvent::Custom(source~, label~, data~) =>
      Some(
        Json::object({
          "type": "custom",
          "source": Json::string(source),
          "label": Json::string(label),
          "data": data,
        }),
      )
    _ => None
  }
}

///|
/// Wire phase of one child fact. `turn` is a direct kernel event of the child
/// run (including the child's own `turn.completed`); `lifecycle` is the
/// subagent extension's own bookkeeping — `spawned`, `background_spawned`,
/// `question_asked`/`question_answered`, `background_exited` and the
/// authoritative `background_terminal`. The two must stay distinguishable: a
/// child turn finishing is not a task terminal, and only the terminal carries
/// the final state/summary.
fn native_child_phase(event : @posoco.TurnEvent) -> String {
  match event {
    @posoco.TurnEvent::Custom(..) => "lifecycle"
    _ => "turn"
  }
}

///|
/// Fields of one `subagent.event` frame: the child attribution the terminal
/// needs to place a live row (`child_session`, `kind`, `parent_call`) plus the
/// normalized child event. `None` when the child event has nothing to render.
fn native_subagent_event_extra(
  event : @subagent_kit.SubagentEvent,
) -> Array[(String, Json)]? {
  match native_child_ev_json(event.event) {
    None => None
    Some(ev) =>
      Some([
        ("child_session", Json::string(event.child_session)),
        ("kind", Json::string(event.kind)),
        ("parent_call", Json::string(event.parent_call)),
        ("phase", Json::string(native_child_phase(event.event))),
        ("ev", ev),
      ])
  }
}

///|
/// Subscribe one sink to the subagent extension's child-run channel, or
/// `None` when the native projection is off (an unsubscribed extension cannot
/// emit anything into the parent's wire).
fn native_subagent_sink(
  hub : EventHub,
  session_id : String,
  native_ui~ : Bool,
) -> ((@subagent_kit.SubagentEvent) -> Unit)? {
  if !native_ui {
    return None
  }
  Some(fn(event) {
    match native_subagent_event_extra(event) {
      Some(extra) => hub.emit_out_of_band(session_id, "subagent.event", extra~)
      None => ()
    }
  })
}

// ──────────────────────────────────────────────────────────────────────────
// Non-blocking question lifecycle
// ──────────────────────────────────────────────────────────────────────────

///|
/// Fields of one `question.asked` frame: the real, already-registered question
/// (`AskQuestionTools::notify_user` parked it), never a synthesized prompt.
/// Field names follow the JS host's `question_event` projection. `short_id` is
/// spelled `@q3` — the exact token the extension's own `notify_user` receipt
/// advertises to the model, so the human and the model name a question the same
/// way (every spelling is accepted back, see `native_question_id_matches`). The
/// opaque `question_id` is the answer key and `kind` is the request word
/// (`input` / `confirm` / `select`) — the frame discriminator already owns
/// `type`.
fn native_question_asked_extra(
  question : @askquestion.AsyncQuestion,
) -> Array[(String, Json)] {
  let options : Array[Json] = []
  for option in question.options() {
    options.push(Json::string(option))
  }
  [
    ("question_id", Json::string(question.id)),
    ("short_id", Json::string("@q" + question.short_id())),
    ("origin_call", Json::string(question.origin_call)),
    ("question", Json::string(question.prompt())),
    // `kind` (not `type`): the envelope already owns `type`, and the
    // question's own type word must never overwrite it.
    ("kind", Json::string(question.type_word())),
    ("options", Json::array(options)),
    ("asked_at", Json::number(question.asked_at.to_double())),
    ("deadline_at", Json::number(question.deadline_at.to_double())),
  ]
}

///|
/// Subscribe one sink to the ask-question extension's lifecycle, or `None`
/// when the native projection is off.
fn native_question_sink(
  hub : EventHub,
  session_id : String,
  native_ui~ : Bool,
) -> ((@askquestion.QuestionEvent) -> Unit)? {
  if !native_ui {
    return None
  }
  Some(fn(event) {
    match event {
      @askquestion.QuestionEvent::Asked(question~) =>
        hub.emit_out_of_band(
          session_id,
          "question.asked",
          extra=native_question_asked_extra(question),
        )
      @askquestion.QuestionEvent::Answered(question_id~) =>
        hub.emit_out_of_band(session_id, "question.answered", extra=[
          ("question_id", Json::string(question_id)),
        ])
    }
  })
}

///|
/// Does a host-supplied answer key name this question? The host may echo
/// whichever form it displayed, so every advertised spelling resolves to the
/// same registry key: the opaque id (`question-3`), the bare number (`3`), the
/// frame's `short_id` (`@q3`), and the JS host's `@3`.
fn native_question_id_matches(question_id : String, raw : String) -> Bool {
  let trimmed = raw.trim()
  if trimmed == question_id {
    return true
  }
  if question_id.has_prefix("question-") {
    let short = question_id[9:].to_owned()
    return trimmed == short || trimmed == "@" + short || trimmed == "@q" + short
  }
  false
}

///|
/// Resolve one non-blocking question through the *existing* UI response
/// command: the host echoes the `question_id` it displayed as `request_id`,
/// and the reply keeps the exact ui_response shape (`text` / `yes`|`no` /
/// `selected`) already decoded for blocking asks. Returns `false` when the id
/// is not an open question of this session, so the caller can fall through to
/// the ordinary `UiRegistry` path.
///
/// A dismissal (`{"cancelled":true}`) is not a question answer: the
/// ask-question extension has no per-question withdrawal, only an answer or
/// the answer deadline, so it stays open here instead of being silently
/// dropped.
fn native_answer_question(
  questions : @askquestion.AskQuestionTools,
  request_id : String,
  response : String,
) -> Bool {
  let mut found : @askquestion.AsyncQuestion? = None
  for question in questions.open_questions() {
    if native_question_id_matches(question.id, request_id) {
      found = Some(question)
      break
    }
  }
  let question = match found {
    Some(question) => question
    None => return false
  }
  let (answer, decode_error) = ui_response_decoded(question.req, response)
  match decode_error {
    Some(_) => return false
    None => ()
  }
  match questions.answer_async(question_id=question.id, response=answer) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
/// The parent's ask-question instance for one session: subscribed when the
/// native projection is on, absent (and unobserved) otherwise.
fn native_question_tools(
  hub : EventHub,
  session_id : String,
  native_ui~ : Bool,
) -> @askquestion.AskQuestionTools? {
  match native_question_sink(hub, session_id, native_ui~) {
    None => None
    Some(sink) => {
      let tools = @askquestion.AskQuestionTools()
      tools.subscribe(sink)
      Some(tools)
    }
  }
}

///|
/// Native session-lifetime task scope.
///
/// Background subagents submit through the Agent-owned task capability, which
/// only exists while one `Agent::run_scoped` is held; the foreground-only
/// alternative would refuse the `subagent` tool's default (background) mode.
/// The scope is therefore acquired once per session and parked on the returned
/// close signal until the host shuts the session down — the JS host's
/// serving-lifetime pattern. It is an *inner* owner: the runtime still owns
/// composition, the turn queue and session identity, and turns keep running on
/// the host group.
///
/// `body` must publish readiness only once its scope is live and then park
/// until the signal is released. A body that fails before publishing is
/// reported and composition continues without a scope: delegation then fails
/// with the extension's own explicit refusal instead of taking the whole
/// session down.
async fn native_scope_owner(
  group : @async.TaskGroup,
  native_ui~ : Bool,
  label : String,
  body : async (() -> Unit, @aqueue.Queue[Unit]) -> Unit,
) -> @aqueue.Queue[Unit]? {
  if !native_ui {
    return None
  }
  let close : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
  let activated : @aqueue.Queue[Result[Unit, String]] = Queue(kind=Blocking(1))
  group.spawn_bg(async fn() {
    let outcome : Result[Unit, String] = Ok(
      body(
        fn() { ignore(activated.try_put(Ok(())) catch { _ => false }) },
        close,
      ),
    ) catch {
      error => Err(error.to_string())
    }
    match outcome {
      Ok(_) => ()
      Err(message) =>
        ignore(activated.try_put(Err(message)) catch { _ => false })
    }
  })
  match activated.get() {
    Ok(_) => Some(close)
    Err(message) => {
      @stdio.stderr.write(
        @utf8.encode(label + ": native task scope unavailable: " + message)[:],
      ) catch {
        _ => ()
      }
      None
    }
  }
}

///|
/// The session's scope body: one `Agent::run_scoped` held for the session
/// lifetime, released by the close signal at shutdown.
async fn native_session_scope(
  group : @async.TaskGroup,
  agent : @posoco.Agent,
  native_ui~ : Bool,
  label : String,
) -> @aqueue.Queue[Unit]? {
  native_scope_owner(group, native_ui~, label, async fn(ready, close) {
    agent.run_scoped(async fn(_agent) {
      ready()
      ignore(close.get())
    })
  })
}

// ──────────────────────────────────────────────────────────────────────────
// Child composition
// ──────────────────────────────────────────────────────────────────────────

///|
/// Child transcripts are memory-only, exactly like the JS host's default: they
/// live as long as the subagent resume registry (the parent Agent), so a fresh
/// process never reuses a stale `subagent-1` transcript. Parent session
/// storage stays the parent's alone.
priv struct NativeChildSessionStore {
  sessions : Map[String, @posoco.Session]
}

///|
fn NativeChildSessionStore::NativeChildSessionStore() -> NativeChildSessionStore {
  { sessions: Map::from_array([]), }
}

///|
fn native_child_session_snapshot(session : @posoco.Session) -> @posoco.Session {
  { messages: session.messages.copy(), metadata: session.metadata.copy(), }
}

///|
impl @posoco.SessionPort for NativeChildSessionStore with fn load(
  self,
  id : String,
) -> @posoco.Session raise @posoco.SessionError {
  match self.sessions.get(id) {
    Some(session) => native_child_session_snapshot(session)
    None => { messages: [], metadata: Map::from_array([]), }
  }
}

///|
impl @posoco.SessionPort for NativeChildSessionStore with fn save(
  self,
  id : String,
  session : @posoco.Session,
) -> Unit raise @posoco.SessionError {
  self.sessions[id] = native_child_session_snapshot(session)
}

///|
impl @posoco.SessionPort for NativeChildSessionStore with fn append_messages(
  self,
  id : String,
  from_index : Int32,
  messages : ArrayView[@posoco.Message],
) -> Unit raise @posoco.SessionError {
  let _ = from_index
  let session = match self.sessions.get(id) {
    Some(value) => native_child_session_snapshot(value)
    None => { messages: [], metadata: Map::from_array([]), }
  }
  let merged = session.messages.copy()
  for message in messages {
    merged.push(message)
  }
  self.sessions[id] = { messages: merged, metadata: session.metadata, }
}

///|
impl @posoco.SessionPort for NativeChildSessionStore with fn truncate(
  self,
  id : String,
  from_index : Int32,
) -> Unit raise @posoco.SessionError {
  let session = match self.sessions.get(id) {
    Some(value) => native_child_session_snapshot(value)
    None => { messages: [], metadata: Map::from_array([]), }
  }
  let len = session.messages.length()
  let keep = if from_index < 0 {
    0
  } else if from_index > len {
    len
  } else {
    from_index
  }
  self.sessions[id] = {
    messages: session.messages[:keep].to_owned(),
    metadata: session.metadata,
  }
}

///|
/// Contribution wrapper: the child's transcript store plus the observers the
/// subagent extension hands over (its `BridgeObserver`, which is what tags
/// every child event with `child_session`/`kind`/`parent_call`).
priv struct NativeChildIo {
  store : NativeChildSessionStore
  observers : Array[&@posoco.Observer]
}

///|
impl @posoco.Extension for NativeChildIo with fn extension_id(
  _self : NativeChildIo,
) -> String {
  "cetas_native_child_io"
}

///|
impl @posoco.Extension for NativeChildIo with fn manifest(self : NativeChildIo) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="cetas_native_child_io",
    sessions=[self.store as &@posoco.SessionPort],
    observers=self.observers,
  )
}

///|
/// Adapter between the ask-question extension's endpoint contract and the
/// subagent extension's parent channel: a child's `ask_question_child` parks
/// until the spawning parent agent answers it with the `answer_question` tool.
/// The two extensions never import each other; this is the only place they
/// meet.
priv struct NativeParentQuestionEndpoint {
  channel : @subagent.ParentQuestionChannel
  child_session : String
}

///|
fn NativeParentQuestionEndpoint::new(
  channel~ : @subagent.ParentQuestionChannel,
  child_session~ : String,
) -> NativeParentQuestionEndpoint {
  { channel, child_session, }
}

///|
fn native_parent_question_error(
  error : @subagent.QuestionError,
) -> @askquestion.QuestionError {
  match error {
    @subagent.QuestionError::Unsupported(detail) =>
      @askquestion.QuestionError::Unsupported(detail)
    @subagent.QuestionError::Cancelled => @askquestion.QuestionError::Cancelled
    @subagent.QuestionError::TimedOut => @askquestion.QuestionError::TimedOut
    @subagent.QuestionError::Io(detail) =>
      @askquestion.QuestionError::Io(detail)
  }
}

///|
impl @askquestion.QuestionEndpoint for NativeParentQuestionEndpoint with fn request(
  self : NativeParentQuestionEndpoint,
  origin_call~ : String,
  req~ : @posoco.UiRequest,
) -> @posoco.UiResponse raise @askquestion.QuestionError {
  self.channel.ask(child_session=self.child_session, origin_call~, req~) catch {
    error => raise native_parent_question_error(error)
  }
}

///|
impl @askquestion.QuestionEndpoint for NativeParentQuestionEndpoint with fn request_with_audience(
  self : NativeParentQuestionEndpoint,
  origin_call~ : String,
  audience~ : String,
  req~ : @posoco.UiRequest,
) -> @posoco.UiResponse raise @askquestion.QuestionError {
  // The parent channel has one answerer (the spawning agent); a host-defined
  // audience token has no routing meaning here.
  let _ = audience
  self.channel.ask(child_session=self.child_session, origin_call~, req~) catch {
    error => raise native_parent_question_error(error)
  }
}

///|
/// Yolo widens every child posture the kind left open; a ReadOnly kind is an
/// explicit capability restriction and stays ReadOnly. Same policy the JS host
/// applies, evaluated against the parent's *live* mode at each spawn.
fn native_effective_child_mode(
  parent : @permission.PermissionMode,
  kind : @permission.PermissionMode,
) -> @permission.PermissionMode {
  match parent {
    @permission.Yolo =>
      match kind {
        @permission.ReadOnly => @permission.ReadOnly
        _ => @permission.Yolo
      }
    _ => kind
  }
}

///|
/// Live-children bookkeeping for one parent session, fed from the subagent
/// event stream. A detached child keeps running after the spawning turn
/// returns, so this meter — not `busy` — decides whether retiring the handle
/// would cancel live work.
priv struct NativeChildMeter {
  live : Map[String, Bool]
}

///|
fn NativeChildMeter::observe(
  self : NativeChildMeter,
  event : @subagent_kit.SubagentEvent,
) -> Unit {
  match event.event {
    @posoco.TurnEvent::TurnStarted => self.live[event.child_session] = true
    @posoco.TurnEvent::TurnCompleted => self.live.remove(event.child_session)
    @posoco.TurnEvent::TurnFailed(_) => self.live.remove(event.child_session)
    _ => ()
  }
}

///|
fn NativeChildMeter::live_count(self : NativeChildMeter) -> Int32 {
  self.live.length()
}

///|
/// Native child composer: assembles one child Agent per spawn. It reuses the
/// parent's model slots through a fresh router value (mutable active selection
/// is never shared), the parent's workspace anchor/approval source, and the
/// reconstructable Cetas core tool face. Depth 1 is structural — the child face
/// never contains `subagent`/`agent_swarm`.
priv struct NativeChildComposer {
  fs : &@workspace.WorkspaceFs
  cwd : String
  home : String
  /// One store for every child of this parent, so `resume` on a child session
  /// id continues the same transcript (a per-spawn store would silently start a
  /// resumed child empty). The parent Agent's lifetime bounds it.
  store : NativeChildSessionStore
  router : @ext_llm.RouterModelPort
  /// Live parent posture, read at each spawn so `/permission` switches apply to
  /// children composed afterwards.
  parent_mode : () -> @permission.PermissionMode
  approval : &@permission.ApprovalSource?
  ui : &@posoco.UiPort?
  /// Parent-agent question channel: a child face that includes `ask_question`
  /// gets `ask_question_child`, answered by the spawning parent.
  question : @subagent.ParentQuestionChannel
  host_group : @async.TaskGroup?
}

///|
/// Fresh router value for one child: provider ports may be shared, the active
/// slot/effort selection never is.
fn native_child_model(
  router : @ext_llm.RouterModelPort,
  slot~ : String,
  effort~ : String?,
) -> &@posoco.Extension raise @subagent.ComposerError {
  let child = @ext_llm.RouterModelPort(
    slots=router.list_slots(),
    model_metadata=router.model_metadata,
    default_slot_id=slot,
  ) catch {
    error =>
      raise @subagent.ComposerError::Failed(
        "child model selection failed: " + error.to_string(),
      )
  }
  match effort {
    Some(effort) =>
      child.select_effort(slot, effort) catch {
        error =>
          raise @subagent.ComposerError::Failed(
            "child effort selection failed: " + error.to_string(),
          )
      }
    None => ()
  }
  child as &@posoco.Extension
}

///|
/// The child's default core face: the same reconstructable capability list the
/// JS host expands, with the platform's shell name resolved.
fn native_child_tool_names() -> Array[String] {
  let names : Array[String] = []
  for capability in @cetas_core.cetas_reconstructable_capabilities() {
    names.push(
      if capability == "shell" {
        if shell_platform_is_windows() {
          "ps1"
        } else {
          "bash"
        }
      } else {
        capability
      },
    )
  }
  names
}

///|
impl @subagent.ChildComposer for NativeChildComposer with fn compose(
  self : NativeChildComposer,
  spec : @subagent.ChildSpec,
) -> @posoco.Agent raise @subagent.ComposerError {
  let child_model = native_child_model(
    self.router,
    slot=spec.slot,
    effort=spec.effort,
  )
  let permission = @permission.PermissionPolicy(
    native_effective_child_mode((self.parent_mode)(), spec.mode),
    approval=self.approval,
    workspace=Some(@devkit.WorkspaceAnchor::WorkspaceAnchor(self.cwd)),
  )
  let exts : Array[&@posoco.Extension] = [
    child_model,
    permission as &@posoco.Extension,
    NativeChildIo::{ store: self.store, observers: spec.observers, }
    as &@posoco.Extension,
  ]
  if spec.context_files {
    // Context-file inheritance (AGENTS.md & friends) needs the host-owned
    // context loader, which this module does not depend on: the child gets the
    // plain Cetas prompt contributor instead of a project bundle.
    exts.push(@cetas_core.Cetas::Cetas() as &@posoco.Extension)
  }
  match spec.skills {
    Some(requested) => {
      let skills = build_cetas_skills(
        ctx={ fs: self.fs, cwd: self.cwd, home: self.home, },
        manuals=@forme.Forme::Forme().builtin_manual_skills(),
        requested=Some(requested),
      ) catch {
        error =>
          raise @subagent.ComposerError::Failed(
            "child skills composition failed: " + error.to_string(),
          )
      }
      match skills {
        Some(skills) => exts.push(skills)
        None => ()
      }
    }
    None => ()
  }
  let tool_names : Array[String] = match spec.tools {
    Some(names) => names
    None => native_child_tool_names()
  }
  // Interactive child faces ask the spawning parent agent, never the human:
  // the parent answers with the `answer_question` tool this composition
  // provides.
  let question : &@askquestion.QuestionEndpoint? = if tool_names.contains(
      "ask_question",
    ) {
    Some(
      NativeParentQuestionEndpoint::new(
        channel=self.question,
        child_session=spec.session_id,
      )
      as &@askquestion.QuestionEndpoint,
    )
  } else {
    None
  }
  let tools = build_cetas_tools(
    ctx={ fs: self.fs, cwd: self.cwd, home: self.home, },
    tool_names,
    question~,
    host_group=self.host_group,
  ) catch {
    error =>
      raise @subagent.ComposerError::Failed(
        "child tool composition failed: " + error.to_string(),
      )
  }
  for ext in tools {
    exts.push(ext)
  }
  match self.ui {
    Some(ui) =>
      exts.push(
        @cetas_core.UiPortExtension::UiPortExtension(
          id="cetas_native_child_ui",
          ui~,
        )
        as &@posoco.Extension,
      )
    None => ()
  }
  @posoco.Agent(
    exts~,
    config=@cetas_core.default_agent_config(
      system_prompt=Some(spec.system_prompt),
    ),
    events=@posoco.EventSystem(),
  ) catch {
    error =>
      raise @subagent.ComposerError::Failed(
        "child agent composition failed: " + error.to_string(),
      )
  }
}

///|
/// Compose the native delegation surface. Called only for the opted-in native
/// projection; the default console never builds it, so no `subagent` tool is
/// offered and no child ever runs.
///
/// `auto_wakeup` stays off: the console never bound a wakeup session and has no
/// wakeup turn driver, so a background result is delivered lazily on the
/// parent's next ordinary turn (the documented default policy) instead of
/// requesting a turn nobody would run.
async fn compose_native_subagents(
  fs : &@workspace.WorkspaceFs,
  home : String,
  cwd : String,
  group : @async.TaskGroup,
  ui : &@posoco.UiPort,
  approval : &@permission.ApprovalSource,
  router : @ext_llm.RouterModelPort,
  parent_mode : () -> @permission.PermissionMode,
  observers~ : Array[(@subagent_kit.SubagentEvent) -> Unit],
) -> &@posoco.Extension {
  // On-disk kind overlays stay optional product configuration: an IO failure
  // must not disable the builtin delegation surface.
  let catalog : @kind.KindCatalog = @kind.KindCatalog::load(home~, cwd~) catch {
    _ => @kind.KindCatalog::builtin()
  }
  let config = @subagent_kit.SubagentConfig::defaults()
  let broker = @subagent.QuestionBroker::QuestionBroker(
    answer_timeout_ms=config.limits.answer_timeout_ms,
  )
  let composer = NativeChildComposer::{
    fs,
    cwd,
    home,
    store: NativeChildSessionStore::NativeChildSessionStore(),
    router,
    parent_mode,
    approval: Some(approval),
    ui: Some(ui),
    question: broker.channel(),
    host_group: Some(group),
  }
  let tools = @subagent.SubagentTools::SubagentTools(
    catalog~,
    config~,
    composer=composer as &@subagent.ChildComposer,
    parent_slot=router.active_slot_id(),
    parent_effort=router.active_effort(),
    parent_selection=Some(fn() {
      (router.active_slot_id(), router.active_effort())
    }),
    observers~,
    auto_wakeup=false,
    question=Some(broker),
  )
  tools as &@posoco.Extension
}
