///|
/// debug.mbt — env-gated debug taps for real-device calibration, both off
/// by default and best-effort (a failure only warns, never fails a session
/// or a turn). Files land under `<home>/.cetas/debug/`:
///
/// - `CETAS_DEBUG_MCP_CATALOG=1` — one `<session-id>-catalog.json` per
///   session after MCP activation: every tool the catalog serves.
/// - `CETAS_DEBUG_WIRE=1` — one `<session-id>-wire.jsonl` per session:
///   `{dir:"in", ...}` at every handler entry (prompt text truncated) and
///   `{dir:"out", ...}` for every outbound update.
///
/// Flags parse like `CETAS_PERMISSION_MODE`: only `1` enables, garbage
/// warns and stays off. Every wire record leads with `"ts"` (epoch ms at
/// emit time) so real-device runs can quantify per-hop latency. Appends are
/// O(1) open-append-write through the native fs (the process fs — the same
/// files `NativeWorkspaceFs` serves); fake-fs tests instead take the
/// read-modify-write workspace-fs path so they observe the same records.

///|
priv struct DebugTaps {
  catalog : Bool
  wire : Bool
}

///|
/// An unrecognized value warns and stays off — a typo never silently turns
/// a tap on.
async fn resolve_debug_flag(
  name~ : String,
  env_value~ : String?,
) -> Bool noraise {
  match env_value {
    None => false
    Some("1") => true
    Some("0") => false
    Some(other) => {
      acp_warn(
        "cetas-acp: " +
        name +
        " '" +
        other +
        "' is not 0 or 1; the debug tap stays off\n",
      )
      false
    }
  }
}

///|
async fn startup_debug_taps() -> DebugTaps noraise {
  let catalog = resolve_debug_flag(
    name="CETAS_DEBUG_MCP_CATALOG",
    env_value=read_env_var("CETAS_DEBUG_MCP_CATALOG"),
  )
  let wire = resolve_debug_flag(
    name="CETAS_DEBUG_WIRE",
    env_value=read_env_var("CETAS_DEBUG_WIRE"),
  )
  { catalog, wire, }
}

///|
/// Serializes the wire file's read-modify-write appends: two interleaved
/// cycles would drop one side's line.
let debug_io_mutex : @async.Mutex = @async.Mutex::Mutex()

///|
/// The native fs needs the directory to exist before the first write
/// (fakes ignore it).
async fn debug_write_file(
  fs : &@workspace.WorkspaceFs,
  dir~ : String,
  path~ : String,
  content~ : String,
) -> Unit noraise {
  debug_io_mutex.acquire() catch {
    _ => return
  }
  defer debug_io_mutex.release()
  fs.mkdir(dir, recursive=true) catch {
    _ => ()
  }
  fs.write_file(path, content) catch {
    _ => acp_warn("cetas-acp: debug write failed (" + path + ")\n")
  }
}

///|
/// Directories the native append path has already ensured exist; process
/// global under `debug_io_mutex` so mkdir runs once per directory.
let debug_dirs_ensured : Map[String, Bool] = Map::from_array([])

///|
/// Native append of one line: open-append-write of just the record, O(1)
/// in file size. The read-modify-write fallback below rewrites the whole
/// file per record, so under streaming every chunk would pay a full-file
/// rewrite — real devices must run this native path. Returns false when
/// the write failed so the caller falls back to the workspace fs.
async fn debug_native_append_line(
  dir~ : String,
  path~ : String,
  line~ : String,
) -> Bool noraise {
  if !debug_dirs_ensured.contains(dir) {
    @fs.mkdir(dir, recursive=true) catch {
      _ => ()
    }
    debug_dirs_ensured[dir] = true
  }
  try {
    @fs.write_file(
      path,
      line + "\n",
      create_mode=@fs.CreateMode::OpenOrCreate,
      permission=0o644,
      append=true,
    )
    true
  } catch {
    _ => false
  }
}

///|
/// A missing file (or a read failure) starts empty; the append is
/// best-effort and never fails the caller. Native fs appends O(1) via
/// open-append-write; a fake fs (or a failed native write) takes the
/// read-modify-write path so fake-fs tests observe the same records.
async fn debug_append_line(
  fs : &@workspace.WorkspaceFs,
  native~ : Bool,
  dir~ : String,
  path~ : String,
  line~ : String,
) -> Unit noraise {
  debug_io_mutex.acquire() catch {
    _ => return
  }
  defer debug_io_mutex.release()
  if native && debug_native_append_line(dir~, path~, line~) {
    return
  }
  fs.mkdir(dir, recursive=true) catch {
    _ => ()
  }
  let existing = match @workspace.read_file_result(fs, path) {
    Content(text) => text
    _ => ""
  }
  fs.write_file(path, existing + line + "\n") catch {
    _ => acp_warn("cetas-acp: debug wire append failed (" + path + ")\n")
  }
}

// ------------------------------------------------------------------ wire tap

///|
/// One wire record carries at most this many UTF-16 code units of prompt
/// text, so a multi-megabyte paste cannot flood the debug file.
const DEBUG_PROMPT_LIMIT = 2048

///|
fn debug_truncate(text : String) -> String {
  if text.length() <= DEBUG_PROMPT_LIMIT {
    text
  } else {
    text.sub(end=DEBUG_PROMPT_LIMIT).to_owned() + "...(truncated)"
  }
}

///|
fn debug_prompt_text(prompt : Array[@acp.ContentBlock]) -> String {
  let parts : Array[String] = []
  for block in prompt {
    match block {
      Text({ text, .. }) => parts.push(text)
      Image(image) => parts.push("[image \{image.mime_type}]")
      Audio(_) => parts.push("[audio]")
      ResourceLink(link) => parts.push("[link \{link.uri}]")
      Resource(_) => parts.push("[resource]")
    }
  }
  debug_truncate(parts.join("\n"))
}

///|
fn debug_join_chars(chars : Array[Char], from : Int, to : Int) -> String {
  let buf = StringBuilder()
  for i in from..<to {
    buf.write_char(chars[i])
  }
  buf.to_string()
}

///|
/// Wire-safe URL: the query string and any userinfo — the two classic token
/// carriers — are cut/masked; scheme, host, and path stay for server
/// identification.
fn debug_mask_url(url : String) -> String {
  let chars = url.to_array()
  let mut content_end = chars.length()
  for i, ch in chars {
    if ch == '?' || ch == '#' {
      content_end = i
      break
    }
  }
  let mut scheme_end = -1
  for i in 0..<content_end {
    if chars[i] == ':' &&
      i + 2 < content_end &&
      chars[i + 1] == '/' &&
      chars[i + 2] == '/' {
      scheme_end = i + 3
      break
    }
  }
  if scheme_end < 0 {
    return debug_join_chars(chars, 0, content_end)
  }
  // Authority runs to the first '/'; an '@' inside it is userinfo — the
  // host after it survives, the credentials before it do not.
  let mut at = -1
  for i in scheme_end..<content_end {
    match chars[i] {
      '/' => break
      '@' => at = i
      _ => ()
    }
  }
  if at < 0 {
    return debug_join_chars(chars, 0, content_end)
  }
  debug_join_chars(chars, 0, scheme_end) +
  "[masked]@" +
  debug_join_chars(chars, at + 1, content_end)
}

///|
/// One injected server's calibration facts: transport, command or a masked
/// URL, and HTTP header *names* only — never values.
fn debug_server_wire_entry(server : @acp.McpServer) -> Json {
  match server {
    Stdio(s) =>
      Json::object(
        Map::from_array([
          ("name", Json::string(s.name)),
          ("transport", Json::string("stdio")),
          ("command", Json::string(s.command)),
          ("args", Json::number(s.args.length().to_double())),
        ]),
      )
    Http(s) =>
      Json::object(
        Map::from_array([
          ("name", Json::string(s.name)),
          ("transport", Json::string("http")),
          ("url", Json::string(debug_mask_url(s.url))),
          (
            "header_names",
            Json::array(s.headers.map(header => Json::string(header.name))),
          ),
        ]),
      )
    Sse(s) =>
      Json::object(
        Map::from_array([
          ("name", Json::string(s.name)),
          ("transport", Json::string("sse")),
          ("url", Json::string(debug_mask_url(s.url))),
          (
            "header_names",
            Json::array(s.headers.map(header => Json::string(header.name))),
          ),
        ]),
      )
  }
}

///|
/// Presence plus a shape summary — additional_directories keep only the
/// count, `_meta` keeps only its top-level key names.
fn debug_presence(fields~ : Array[(String, Json)]) -> Json {
  Json::object(Map::from_array(fields))
}

///|
fn debug_new_session_params(params : @acp.NewSessionParams) -> Json {
  let servers : Array[Json] = []
  for server in params.mcp_servers {
    servers.push(debug_server_wire_entry(server))
  }
  let directories = match params.additional_directories {
    Value(dirs) =>
      debug_presence(fields=[
        ("present", Json::boolean(true)),
        ("count", Json::number(dirs.length().to_double())),
      ])
    _ => debug_presence(fields=[("present", Json::boolean(false))])
  }
  let meta = match params.meta {
    Value(Json::Object(meta_fields)) => {
      let keys : Array[Json] = []
      for key, _value in meta_fields {
        keys.push(Json::string(key))
      }
      debug_presence(fields=[
        ("present", Json::boolean(true)),
        ("keys", Json::array(keys)),
      ])
    }
    Value(_) => debug_presence(fields=[("present", Json::boolean(true))])
    _ => debug_presence(fields=[("present", Json::boolean(false))])
  }
  Json::object(
    Map::from_array([
      ("cwd", Json::string(params.cwd)),
      ("additional_directories", directories),
      ("mcp_servers", Json::array(servers)),
      ("meta", meta),
    ]),
  )
}

///|
fn debug_prompt_params(params : @acp.PromptParams) -> Json {
  Json::object(
    Map::from_array([
      ("session_id", Json::string(params.session_id)),
      ("prompt", Json::string(debug_prompt_text(params.prompt))),
    ]),
  )
}

///|
fn debug_session_params(session_id : String) -> Json {
  Json::object(Map::from_array([("session_id", Json::string(session_id))]))
}

///|
fn debug_restore_params(session_id~ : String, cwd~ : String) -> Json {
  Json::object(
    Map::from_array([
      ("session_id", Json::string(session_id)),
      ("cwd", Json::string(cwd)),
    ]),
  )
}

///|
fn debug_config_option_params(
  params : @acp.SetSessionConfigOptionParams,
) -> Json {
  let value = match params.value {
    @acp.SessionConfigValue::ValueId(id) => Json::string(id)
    @acp.SessionConfigValue::Boolean(flag) => Json::boolean(flag)
  }
  Json::object(
    Map::from_array([
      ("session_id", Json::string(params.session_id)),
      ("config_id", Json::string(params.config_id)),
      ("value", value),
    ]),
  )
}

///|
fn debug_set_mode_params(params : @acp.SetSessionModeParams) -> Json {
  Json::object(
    Map::from_array([
      ("session_id", Json::string(params.session_id)),
      ("mode_id", Json::string(params.mode_id)),
    ]),
  )
}

///|
fn debug_list_params(params : @acp.ListSessionsParams) -> Json {
  let cwd = match params.cwd {
    Value(want) => Json::string(want)
    _ => Json::null()
  }
  Json::object(Map::from_array([("cwd", cwd)]))
}

///|
/// Append one inbound record. `session/list` has no session of its own and
/// logs under the `host` id.
async fn CetasAcpHost::debug_wire_in(
  self : CetasAcpHost,
  session_id~ : String,
  rpc_method~ : String,
  params~ : Json,
) -> Unit noraise {
  if !self.wire_log {
    return
  }
  let record = Json::object(
    Map::from_array([
      ("ts", Json::number(@async.now().to_double())),
      ("dir", Json::string("in")),
      ("method", Json::string(rpc_method)),
      ("params", params),
    ]),
  )
  debug_append_line(
    self.fs,
    native=self.wire_native_append,
    dir=@cetas_core.debug_dir(self.home),
    path=@cetas_core.debug_wire_path(self.home, session_id),
    line=record.stringify(),
  )
}

///|
/// Wrap the invocation context so every outbound `session/update` is
/// appended to the wire file before reaching the transport. The
/// notification broker is the one seam the host owns over the bridge's
/// whole send path (pump and flush alike), so ext-acp stays untouched.
fn CetasAcpHost::debug_tap_context(
  self : CetasAcpHost,
  context : @acp.AgentContext,
) -> @acp.AgentContext {
  if !self.wire_log {
    return context
  }
  let fs = self.fs
  let home = self.home
  let native = self.wire_native_append
  let inner = context.notification_broker
  @acp.agent_context(request_broker=context.request_broker, notification_broker=async fn(
    notification,
  ) {
    match notification {
      SessionUpdate(params) => {
        let payload : Json = @acp.session_update_params_to_json(params) catch {
          _ =>
            Json::object(
              Map::from_array([
                ("session_id", Json::string(params.session_id)),
                ("update", Json::string("unserializable")),
              ]),
            )
        }
        let record = Json::object(
          Map::from_array([
            ("ts", Json::number(@async.now().to_double())),
            ("dir", Json::string("out")),
            ("method", Json::string("session/update")),
            ("update", payload),
          ]),
        )
        debug_append_line(
          fs,
          native~,
          dir=@cetas_core.debug_dir(home),
          path=@cetas_core.debug_wire_path(home, params.session_id),
          line=record.stringify(),
        )
      }
      _ => ()
    }
    inner(notification)
  })
}

///|
/// The same wire strings the protocol codec emits for `stopReason`.
fn debug_stop_reason(reason : @acp.StopReason) -> Json {
  Json::string(
    match reason {
      EndTurn => "end_turn"
      MaxTokens => "max_tokens"
      MaxTurnRequests => "max_turn_requests"
      Refusal => "refusal"
      Cancelled => "cancelled"
    },
  )
}

///|
fn debug_handler_error_text(error : @acp.HandlerError) -> String {
  match error {
    Application(message~) => message
    InvalidParams(message~) => message
    Cancelled => "cancelled"
    UnavailableOperation(method_name~) => "unavailable: " + method_name
  }
}

///|
/// The prompt's settlement record, appended on the return path after the
/// bridge has closed: `stop_reason` when the turn answers, `stop_reason`
/// `null` plus a one-line `error` when it raises — the cancelled and error
/// branches included, so a calibration pass can pair the streamed updates
/// with the request's outcome.
async fn CetasAcpHost::debug_wire_prompt_out(
  self : CetasAcpHost,
  session_id~ : String,
  outcome~ : Result[@acp.PromptResult, @acp.HandlerError],
) -> Unit noraise {
  if !self.wire_log {
    return
  }
  let fields : Array[(String, Json)] = [
    ("ts", Json::number(@async.now().to_double())),
    ("dir", Json::string("out")),
    ("method", Json::string("session/prompt")),
  ]
  match outcome {
    Ok(result) =>
      fields.push(("stop_reason", debug_stop_reason(result.stop_reason)))
    Err(error) => {
      fields.push(("stop_reason", Json::null()))
      fields.push(("error", Json::string(debug_handler_error_text(error))))
    }
  }
  debug_append_line(
    self.fs,
    native=self.wire_native_append,
    dir=@cetas_core.debug_dir(self.home),
    path=@cetas_core.debug_wire_path(self.home, session_id),
    line=Json::object(Map::from_array(fields)).stringify(),
  )
}

// -------------------------------------------------------------- catalog dump

///|
fn debug_host_kind_name(kind : HostKind) -> String {
  match kind {
    Generic => "generic"
    Lody => "lody"
    Paseo => "paseo"
  }
}

///|
/// `source` separates tools injected through `mcpServers` from the ones
/// composed locally.
fn debug_tool_entry(def : @posoco.ToolDef, source~ : String) -> Json {
  Json::object(
    Map::from_array([
      ("name", Json::string(def.name.to_string())),
      ("description", Json::string(def.description)),
      ("input_schema", def.input_schema),
      ("source", Json::string(source)),
    ]),
  )
}

///|
/// One dump per session assembly (overwrites); a failure only warns.
async fn debug_dump_catalog(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
  session_id~ : String,
  host_kind~ : HostKind,
  injected~ : Bool,
  mcp_tools~ : Array[@posoco.ToolDef],
  base_tools~ : Array[@posoco.ToolDef],
) -> Unit noraise {
  let mcp_source = if injected { "injected" } else { "local" }
  let tools : Array[Json] = []
  for def in mcp_tools {
    tools.push(debug_tool_entry(def, source=mcp_source))
  }
  for def in base_tools {
    tools.push(debug_tool_entry(def, source="local"))
  }
  let json = Json::object(
    Map::from_array([
      ("session_id", Json::string(session_id)),
      ("host_profile", Json::string(debug_host_kind_name(host_kind))),
      ("mcp_source", Json::string(mcp_source)),
      (
        "schema_note",
        Json::string(
          "input_schema is the Kernel-sanitized schema carried by each ToolDef; ext-mcp does not retain the server's raw schema. Base tool schemas are as declared.",
        ),
      ),
      ("tools", Json::array(tools)),
    ]),
  )
  debug_write_file(
    fs,
    dir=@cetas_core.debug_dir(home),
    path=@cetas_core.debug_catalog_path(home, session_id),
    content=json.stringify(indent=2) + "\n",
  )
}
