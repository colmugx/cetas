///|
/// host_profile.mbt — detect which delegation host a session's injected
/// mcpServers belong to, and mount the matching prompt section.

///|
/// Detected from the `session/new` mcpServers names; `Generic` is the
/// no-host default.
priv enum HostProfile {
  Generic
  Lody
  Paseo
}

///|
/// Lody wins the same-name round: the fixed check order (lody, then paseo)
/// means a config injecting both hosts mounts one delegation prompt section,
/// not two overlapping ones.
fn detect_host_profile(mcp_server_names : Array[String]) -> HostProfile {
  for name in mcp_server_names {
    if @lody_kit.is_lody_server(name) {
      return Lody
    }
  }
  if @paseo_kit.detect_from_server_names(mcp_server_names) {
    return Paseo
  }
  Generic
}

///|
fn host_prompt_section(profile : HostProfile) -> String? {
  match profile {
    Lody => Some(@lody_kit.prompt_section())
    Paseo => Some(@paseo_kit.prompt_section())
    Generic => None
  }
}

///|
/// The session system prompt: the cetas product prompt plus the mounted
/// host delegation section, if any.
fn compose_system_prompt(profile : HostProfile, cwd~ : String) -> String {
  match host_prompt_section(profile) {
    Some(section) => @cetas_core.cetas_system_prompt(cwd~) + "\n\n" + section
    None => @cetas_core.cetas_system_prompt(cwd~)
  }
}

///|
fn acp_mcp_server_names(servers : Array[@acp.McpServer]) -> Array[String] {
  servers.map(server => acp_mcp_server_name(server))
}
