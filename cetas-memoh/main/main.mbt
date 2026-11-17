///|
/// cetas-memoh — first-class Posoco agent runtime for Memoh.
///
/// stdout is ACP JSON-RPC only. Durable provider state lives under
/// CETAS_MEMOH_HOME (default $HOME/.cetas-memoh; Memoh generic ACP currently
/// supplies HOME=/data). Conversation continuity is owned by Memoh.
const CETAS_MEMOH_VERSION = "0.1.2"

///|
/// Independent cetas-memoh release version. This runtime does not follow the
/// Cetas product release train.
async fn main {
  let args = @env.args()
  let argv : Array[String] = []
  for i = 1; i < args.length(); i = i + 1 {
    argv.push(args[i])
  }
  let action = @lib.parse_memoh_invocation(argv)
  match action {
    @lib.MemohVersion => {
      println("cetas-memoh \{CETAS_MEMOH_VERSION}")
      return
    }
    @lib.MemohHelp => {
      println(@lib.memoh_usage())
      return
    }
    _ => ()
  }
  let home = @lib.cetas_memoh_home()
  if action is @lib.MemohInvalid(_) {
    match action {
      @lib.MemohInvalid(reason) =>
        @stdio.stderr.write(
          @utf8.encode("cetas-memoh: " + reason + "\n" + @lib.memoh_usage() + "\n")[:],
        )
      _ => ()
    }
    return
  }
  if action is @lib.MemohSetup(_) {
    let provider = match action {
      @lib.MemohSetup(provider) => provider
      _ => ""
    }
    let result = @lib.run_setup(home~, provider~) catch {
      error => {
        @stdio.stderr.write(
          @utf8.encode("cetas-memoh: setup failed: " + error.to_string() + "\n")[:],
        )
        return
      }
    }
    println("cetas-memoh: " + result)
    return
  }
  if action is @lib.MemohLogin(_) {
    let provider = match action {
      @lib.MemohLogin(provider) => provider
      _ => ""
    }
    @lib.run_memoh_login(home~, provider~) catch {
      error => {
        @stdio.stderr.write(
          @utf8.encode("cetas-memoh: login failed: " + error.to_string() + "\n")[:],
        )
      }
    }
    return
  }
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
          @utf8.encode("cetas-memoh: startup failed: \{error.to_string()}\n")[:],
        )
        return
      }
    }
    let spec = match host.agent_spec() {
      Ok(value) => value
      Err(_) => {
        @stdio.stderr.write(
          @utf8.encode("cetas-memoh: ACP endpoint composition failed\n")[:],
        )
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
