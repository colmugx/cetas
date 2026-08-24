///|
/// cetas-acp — serve one cetas agent as an ACP v1 agent over stdio.
///
/// Protocol contract: stdout carries newline-delimited ACP JSON-RPC frames
/// only; diagnostics go to stderr (the acp.mbt runtime's sanitized trace).
/// Launch from the project root — tools run in the process working
/// directory, matching how Zed spawns ACP agents.
///
/// Resolution: `CETAS_HOME` overrides the cetas home directory (settings,
/// credentials, sessions); `HOME` is the default. A model provider must be
/// configured (`~/.cetas/settings.json` or an existing cetas login) — an
/// agent without a model cannot serve prompts, so startup fails loudly on
/// stderr and exits.
///
/// MCP servers declared in mcp.json connect lazily at the first turn by
/// default; `CETAS_MCP_MODE=eager` connects them all at startup instead.

///|
/// This module's version, reported in `initialize` as the agent version.
const CETAS_ACP_VERSION = "0.1.0"

///|
async fn main {
  let home = match @env.get_env_var("CETAS_HOME") {
    Some(value) if value != "" => value
    _ =>
      match @env.get_env_var("HOME") {
        Some(value) => value
        None => "."
      }
  }
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => "."
  }
  let mcp_mode : @mcp.LoadMode = match @env.get_env_var("CETAS_MCP_MODE") {
    Some("eager") => @mcp.LoadMode::Eager
    _ => @mcp.LoadMode::Lazy
  }
  // The whole lifecycle runs inside one task group: stdio MCP servers spawn
  // their child processes on it, and the group ends (cancelling them) only
  // at stdin EOF.
  @async.with_task_group(group => {
    let host = @lib.CetasAcpHost(
      home~,
      cwd~,
      agent_version=CETAS_ACP_VERSION,
      mcp_group=group,
      mcp_mode~,
    ) catch {
      error => {
        @stdio.stderr.write(
          "cetas-acp: agent composition failed: \{error.to_string()}\n",
        )
        return
      }
    }
    let spec = match host.agent_spec() {
      Ok(spec) => spec
      Err(_) => {
        @stdio.stderr.write("cetas-acp: endpoint composition failed\n")
        return
      }
    }
    let endpoint = @acp.agent_endpoint_from_spec(spec)
    let config : @acp.AgentProtocolConfig = {
      agent_capabilities: Value(endpoint.capabilities()),
      auth_methods: endpoint.auth_methods(),
      agent_info: Omitted,
    }
    // The loop ends at stdin EOF; stdout stays pure ACP frames. The lazy model
    // refresh runs alongside serving: composition already announced the cached
    // (or static) list, and the refresh swaps in the live list and pushes a
    // config_option_update once it lands. refresh_model_lists never raises, so
    // it cannot fail the task group; stdin EOF cancels it with the group.
    let _ = group.spawn(() => host.refresh_model_lists())
    @acp.agent_serve_stdio_with_outbound(
      endpoint~,
      context_factory=channel => @acp.agent_context_over_channel(channel~),
      initial_state=@acp.agent_adapter_state_new(
        protocol=@acp.agent_protocol_state_new(config~),
      ),
    )
  })
}
