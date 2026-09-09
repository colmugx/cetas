///|
/// cetas-acp — serve one cetas agent as an ACP v1 agent over stdio.
///
/// stdout carries newline-delimited ACP JSON-RPC frames only; diagnostics
/// go to stderr. `--version` prints the version and exits. `CETAS_HOME`
/// overrides the cetas home directory (default: platform home —
/// `USERPROFILE` on Windows, `HOME` elsewhere). A model provider
/// must be configured — startup fails loudly otherwise.
/// `CETAS_MCP_MODE=eager` connects mcp.json servers at startup instead of
/// lazily at the first turn. `CETAS_GOAL=<condition>` arms the goal runner
/// (personal host) for each session; regular turns are unaffected.

///|
const CETAS_ACP_VERSION = "0.3.2"

///|
async fn main {
  if @env.args().contains("--version") {
    println("cetas-acp \{CETAS_ACP_VERSION}")
    return
  }
  let home = @cetas_core.cetas_home()
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => "."
  }
  let mcp_mode : @mcp.LoadMode = match @env.get_env_var("CETAS_MCP_MODE") {
    Some("eager") => @mcp.LoadMode::Eager
    _ => @mcp.LoadMode::Lazy
  }
  // The whole lifecycle runs inside one task group: it ends (cancelling
  // stdio MCP child processes) only at stdin EOF.
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
    // The lazy model refresh runs alongside serving and pushes a
    // config_option_update once it lands; stdin EOF cancels it with the
    // group.
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
