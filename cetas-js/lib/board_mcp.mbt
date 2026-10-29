///|
/// A Board-facing, per-role view of the host MCP bridge. The parent bridge
/// owns discovery, OAuth and connections; the Board only filters names and
/// never constructs a second set of servers.
priv struct BoardMcp {
  bridge : @mcp.MCPToolBridge
}

///|
fn BoardMcp::BoardMcp(bridge~ : @mcp.MCPToolBridge) -> BoardMcp {
  { bridge, }
}

///|
fn BoardMcp::catalog_json(self : BoardMcp) -> Json {
  self.bridge.server_catalog_json()
}

///|
fn mcp_tool_allowed(name : String, config : TeamMcp) -> Bool {
  if !config.enabled {
    return false
  }
  if !config.tools.is_empty() && !config.tools.contains(name) {
    return false
  }
  if config.all {
    return true
  }
  for server in config.servers {
    if name.has_prefix(server + "__") {
      return true
    }
  }
  false
}

///|
fn BoardMcp::read_tools(self : BoardMcp, config : TeamMcp) -> Array[String] {
  self.bridge
  .list_tools()
  .filter_map(def => {
    let name = def.name.to_string()
    if mcp_tool_allowed(name, config) {
      Some(name)
    } else {
      None
    }
  })
}

///|
fn BoardMcp::extension(
  self : BoardMcp,
  role : String,
  config : TeamMcp,
) -> &@posoco.Extension? {
  let tools = self.read_tools(config)
  if tools.is_empty() {
    return None
  }
  Some(
    BoardMcpTools::{ bridge: self.bridge, tools, role, } as &@posoco.Extension,
  )
}

///|
/// The child-visible MCP face. `execute` re-checks the same allowlist as
/// `list_tools`: a model that guesses a hidden namespaced name cannot route
/// through the parent bridge.
priv struct BoardMcpTools {
  bridge : @mcp.MCPToolBridge
  tools : Array[String]
  role : String
}

///|
impl @posoco.ToolProvider for BoardMcpTools with fn list_tools(
  self : BoardMcpTools,
) -> Array[@posoco.ToolDef] {
  self.bridge
  .list_tools()
  .filter(def => self.tools.contains(def.name.to_string()))
}

///|
impl @posoco.ToolProvider for BoardMcpTools with fn execute(
  self : BoardMcpTools,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let name = ctx.name.to_string()
  if !self.tools.contains(name) {
    raise @posoco.RuntimeError::UnknownTool(
      "MCP tool is not enabled for this Board role: " + name,
    )
  }
  @posoco.ToolProvider::execute(self.bridge, ctx)
}

///|
impl @posoco.Extension for BoardMcpTools with fn extension_id(
  self : BoardMcpTools,
) -> String {
  "board_mcp_" + self.role
}

///|
impl @posoco.Extension for BoardMcpTools with fn manifest(self : BoardMcpTools) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="board_mcp_" + self.role, tools=[self])
}
