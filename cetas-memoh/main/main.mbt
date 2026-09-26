///|
/// cetas-memoh — first-class Posoco agent runtime for Memoh.
///
/// stdout is ACP JSON-RPC only. Durable provider state lives under
/// CETAS_MEMOH_HOME (default $HOME/.cetas-memoh; Memoh generic ACP currently
/// supplies HOME=/data). Conversation continuity is owned by Memoh.
const CETAS_MEMOH_VERSION = "0.5.1"

///|
async fn main {
  if @env.args().contains("--version") {
    println("cetas-memoh \{CETAS_MEMOH_VERSION}")
    return
  }
  let home = @lib.cetas_memoh_home()
  let cwd = match @env.current_dir() {
    Some(value) => value
    None => "."
  }
  @async.with_task_group(group => {
    let host = @lib.MemohHost(
      home~,
      cwd~,
      mcp_group=group,
      version=CETAS_MEMOH_VERSION,
    ) catch {
      error => {
        @stdio.stderr.write(
          "cetas-memoh: startup failed: \{error.to_string()}\n",
        )
        return
      }
    }
    let spec = match host.agent_spec() {
      Ok(value) => value
      Err(_) => {
        @stdio.stderr.write("cetas-memoh: ACP endpoint composition failed\n")
        return
      }
    }
    let endpoint = @acp.agent_endpoint_from_spec(spec)
    let protocol : @acp.AgentProtocolConfig = {
      agent_capabilities: Value(endpoint.capabilities()),
      auth_methods: endpoint.auth_methods(),
      agent_info: Omitted,
    }
    @acp.agent_serve_stdio_with_outbound(
      endpoint~,
      context_factory=channel => @acp.agent_context_over_channel(channel~),
      initial_state=@acp.agent_adapter_state_new(
        protocol=@acp.agent_protocol_state_new(config=protocol),
      ),
    )
    host.shutdown()
  })
}
