///|
/// Console-side MCP composition: one bridge per session, so each session's
/// server set and catalog stay private.
///
/// Lazy by design — discovery never connects, the first turn never waits on a
/// handshake, and a server that never answers cannot block composition. The
/// bridge joins the agent as a tail extension (after the session's routing
/// table is captured), exactly like the ACP and JS roots, so its manifest
/// tools are not double-counted in the static catalog.

///|
async fn compose_mcp_bridge(
  fs : &@workspace.WorkspaceFs,
  home : String,
  cwd : String,
  group : @async.TaskGroup,
  lifetime_group : @async.TaskGroup?,
  label : String,
) -> @mcp.MCPToolBridge raise @posoco.CompositionError {
  let bridge = match
    @mcp.MCPToolBridge::discover(
      cwd~,
      user_mcp_json=@cetas_core.mcp_config_path(home),
      mode=@mcp.LoadMode::Lazy,
    ) {
    Ok(bridge) => bridge
    Err(message) =>
      // A malformed server file must not silently disable every MCP tool.
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=label + ".mcp",
        detail=message,
      )
  }
  // Connection actors run on posoco's core-async stack and outlive the bridge;
  // stdio children stay on the host I/O group. Without a lifetime group a
  // connect fails honestly instead of parking an owner nobody runs.
  match lifetime_group {
    Some(lifetime) => bridge.attach(group, lifetime~)
    None => bridge.attach(group)
  }
  group.spawn_bg(() => {
    let transport = @oauth.DefaultOAuthHttpTransport::DefaultOAuthHttpTransport()
    // @async.now() is epoch milliseconds; OAuth wants epoch seconds.
    @mcp_host.cetas_mcp_inject_stored_tokens(
      bridge,
      fs,
      home,
      transport,
      (@async.now() / 1000L).to_int(),
    )
    bridge.start_probes()
  })
  bridge
}

///|
/// Keep static tools winning name collisions against lazily discovered MCP
/// servers: live tools join as the bridge's own contribution group after
/// composition, where the aggregate's collision check cannot see them.
fn reserve_mcp_tool_names(
  bridge : @mcp.MCPToolBridge,
  base_defs : Array[@posoco.ToolDef],
) -> Unit {
  let names : Array[Json] = []
  for def in base_defs {
    names.push(Json::string(def.name.to_string()))
  }
  @mcp.mcp_bridge_set_reserved_tools_json(
    bridge,
    Json::array(names).stringify(),
  )
}

///|
/// Wrap the session runtime so MCP-namespaced tools route through the bridge:
/// lazy activation adds tools after composition, which the captured static
/// bindings cannot reach. Every other call delegates unchanged.
fn compose_mcp_runtime(
  bridge : @mcp.MCPToolBridge,
  model : &@posoco.ModelPort,
) -> @mcp.McpRuntime {
  let base = @runtime.PortRuntime(model~)
  @mcp.McpRuntime(bridge~, fallback=base as &@runtime.Runtime)
}

///|
/// Device-code delivery for the interactive login. `notify` is synchronous, so
/// the code rides the event stream the terminal already renders rather than a
/// blocking modal: the user reads it, authorizes in the browser, and the flow
/// polls on its own.
priv struct ConsoleMcpAuthInteraction {
  hub : EventHub
  session_id : String
}

///|
fn ConsoleMcpAuthInteraction::ConsoleMcpAuthInteraction(
  hub : EventHub,
  session_id : String,
) -> ConsoleMcpAuthInteraction {
  { hub, session_id, }
}

///|
impl @oauth.AuthInteraction for ConsoleMcpAuthInteraction with fn notify(
  self : ConsoleMcpAuthInteraction,
  message : @oauth.AuthMessage,
) -> Unit {
  let extra : Array[(String, Json)] = match message {
    @oauth.AuthMessage::DeviceCode(uri, code) =>
      [
        ("verification_uri", Json::string(uri)),
        ("user_code", Json::string(code)),
        ("hint", Json::string("open the URL and enter the code")),
      ]
    @oauth.AuthMessage::AuthUrl(url) => [("url", Json::string(url))]
    @oauth.AuthMessage::Progress(message) =>
      [("message", Json::string(message))]
  }
  self.hub.emit(self.session_id, "", "mcp.login", extra~)
}

///|
/// The flow polls until it settles or the process goes away; there is no
/// per-request cancellation surface to consult here.
impl @oauth.AuthInteraction for ConsoleMcpAuthInteraction with fn is_cancelled(
  _self : ConsoleMcpAuthInteraction,
) -> Bool {
  false
}

///|
/// `/mcp login <server>`: the extension's own `mcp` command is read-only and
/// rejects the action, so the host intercepts it before the ports loop — the
/// same split the JS host uses.
pub async fn ConsoleRuntime::mcp_login_outcome(
  self : ConsoleRuntime,
  session_id : String,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome? noraise {
  if id != "mcp" {
    return None
  }
  let fields = match args {
    Json::Object(fields) => fields
    _ => return None
  }
  match fields.get("action") {
    Some(Json::String("login")) => ()
    _ => return None
  }
  let server = match fields.get("server") {
    Some(Json::String(server)) if server.trim().length() > 0 => server
    _ =>
      return Some(
        @posoco.CommandOutcome::Failure(reason="login requires a server name"),
      )
  }
  let handle = match self.resolve_handle(Some(session_id)) {
    Ok(handle) => handle
    Err(reason) => return Some(@posoco.CommandOutcome::Failure(reason~))
  }
  let bridge = match handle.mcp {
    Some(bridge) => bridge
    None =>
      return Some(
        @posoco.CommandOutcome::Failure(
          reason="this session composed no MCP bridge",
        ),
      )
  }
  let outcome = @mcp_host.cetas_mcp_login(
    bridge,
    server,
    self.fs,
    self.home,
    @oauth.DefaultOAuthHttpTransport::DefaultOAuthHttpTransport(),
    ConsoleMcpAuthInteraction::ConsoleMcpAuthInteraction(self.hub, session_id),
  )
  Some(
    match outcome {
      Ok(feedback) =>
        @posoco.CommandOutcome::Success(
          feedback~,
          structured=None,
          ui_hint=Some(@posoco.UiHint::None),
        )
      Err(reason) => @posoco.CommandOutcome::Failure(reason~)
    },
  )
}
