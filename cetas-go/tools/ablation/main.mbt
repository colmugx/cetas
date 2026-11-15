///|
/// Composition memory ablation: boot the cetas-core stack layer by layer,
/// gated by the PHASE env var, and park so an external sampler can read RSS.
/// Phases (cumulative):
///   platform  — build_cetas_platform (settings, credentials, catalogs)
///   session   — + build_cetas_session (extension assembly, no recipe exts)
///   agent     — + compose_cetas_agent (first agent, event system)
///   turn      — + one zero-content turn through the in-process port
/// The model port is always in-process: this isolates composition memory,
/// not transport.
fn ablation_answer() -> String {
  let buf = StringBuilder()
  let mut paragraph = ""
  for _ in 0..<128 {
    paragraph = paragraph + "0123456789abcdef ghij "
  }
  for i in 0..<4 {
    buf.write_string("Paragraph \{i}: \{paragraph}\n\n")
  }
  buf.to_string()
}

///|
priv struct AblationModel {
  answer : String
}

///|
impl @posoco.ModelPort for AblationModel with fn chat(
  self,
  _scope,
  messages : ArrayView[@posoco.Message],
  _tools,
  _options,
  _stream,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let completion : @posoco.Completion = @posoco.Completion(
    content=[@posoco.Content::Text(self.answer)],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
    usage=None,
  )
  { completion, processed_messages: messages.to_owned() }
}

///|
impl @posoco.ModelPort for AblationModel with fn compact(
  _self,
  _scope,
  _messages,
  _tools,
  _options,
  _trigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse("AblationModel does not compact")
}

///|
impl @posoco.ModelPort for AblationModel with fn provider_config(_self) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
fn ablation_router() -> @ext_llm.RouterModelPort {
  let port : &@posoco.ModelPort = { answer: ablation_answer() }
  let slot = @ext_llm.ModelSlot::ModelSlot(
    id="main",
    label="main",
    provider_id="probe",
    model_id="probe-model",
    port~,
  )
  @ext_llm.RouterModelPort(slots=[slot]) catch {
    error => abort("ablation router: " + error.to_string())
  }
}

///|
fn env_phase() -> String {
  match @env.get_env_var("PHASE") {
    Some(value) => value
    None => "agent"
  }
}

///|
async fn main {
  let phase = env_phase()
  let home = @fs.tmpdir(prefix="cetas-ablate-")
  let fs = @workspace.NativeWorkspaceFs()
  fs.mkdir(home + "/.cetas", recursive=true) catch { _ => () }
  fs.write_file(
    home + "/.cetas/settings.json",
    "{\"providers\":{\"opencode\":{\"api_key\":\"sk-fixture\"}}}",
  ) catch { _ => () }
  let cwd = @fs.tmpdir(prefix="cetas-ablate-ws-")
  println("MARK base")
  @async.sleep(300)
  let platform = @cetas_core.build_cetas_platform(
    home=home,
    cwd=cwd,
    fs,
    permission_mode=@permission.PermissionMode::Yolo,
  ) catch {
    error => abort("platform: " + error.to_string())
  }
  println("MARK platform")
  @async.sleep(300)
  if phase == "platform" {
    println("MARK done")
    @async.sleep(4000)
    return
  }
  let session = @cetas_core.build_cetas_session(
    platform=platform,
    cwd=cwd,
    router=Some(ablation_router()),
    label="cetas-ablate",
  ) catch {
    error => abort("session: " + error.to_string())
  }
  println("MARK session")
  @async.sleep(300)
  if phase == "session" {
    println("MARK done")
    @async.sleep(4000)
    return
  }
  let agent = @cetas_core.compose_cetas_agent(session=session)
  println("MARK agent")
  @async.sleep(300)
  if phase == "console-noui" || phase == "console" {
    let native_ui = phase == "console"
    @async.with_task_group(
      group => {
        let console_fs = @workspace.NativeWorkspaceFs()
        let console_fs_ref : &@workspace.WorkspaceFs = console_fs
        let config = @console.console_config(
          console_fs_ref,
          home,
          "cetas-native",
          "cetas-native/0.1",
          native_ui~,
          permission_mode=@permission.PermissionMode::Yolo,
        )
        let runtime = @console.compose_console_runtime(config, cwd, group)
        runtime.attach_sink(fn(frame : String) {
          // Drain: delivery must not queue up behind an unread sink.
          ignore(frame)
        })
        let snapshot = runtime.runtime_json()
        ignore(snapshot)
        println("MARK console \{phase}")
        @async.sleep(1500)
        runtime.shutdown_all()
        ignore(group)
      },
    )
    println("MARK done")
    @async.sleep(4000)
    return
  }
  if phase == "turn" {
    let input : @posoco.Message = @posoco.Message::UserMessage(content=[
      @posoco.Content::Text("one probe turn"),
    ])
    ignore(agent.run_turn(input, "ablate-session"))
    println("MARK turn")
  }
  println("MARK done")
  @async.sleep(4000)
}
