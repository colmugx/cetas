///|
/// mcp_servers.mbt — pure mapping from ACP `McpServer` declarations onto
/// ext-mcp `MCPServerConfig`s. Auth is always `NoAuth`: ACP carries tokens
/// as Authorization headers, which map onto the transport's `auth_token`.

///|
/// The transport re-adds the `Bearer ` scheme on the wire, so a prefixed
/// value round-trips unchanged; a schemeless value passes through as-is.
fn strip_bearer_prefix(value : String) -> String {
  if value.has_prefix("Bearer ") {
    value["Bearer ".length():].to_owned()
  } else {
    value
  }
}

///|
fn acp_mcp_server_name(server : @acp.McpServer) -> String {
  match server {
    Stdio(s) => s.name
    Http(s) => s.name
    Sse(s) => s.name
  }
}

///|
/// Map one ACP declaration onto an ext-mcp config. Http: the FIRST
/// Authorization header becomes the auth token (`Bearer ` stripped); every
/// other named header forwards as an extra — upstream applies extras last,
/// so a repeated Authorization's last declaration wins on the wire. Empty
/// header names are skipped and reported by `acp_invalid_headers`. Sse is
/// refused (capability negotiation already rejects it; this is the
/// typed-payload belt-and-braces refusal).
fn acp_mcp_to_config(
  server : @acp.McpServer,
) -> Result[@mcp.MCPServerConfig, String] {
  match server {
    Stdio(s) => {
      let extra_env : Map[String, String] = Map::from_array(
        s.env.map(entry => (entry.name, entry.value)),
      )
      Ok(
        @mcp.MCPServerConfig::MCPServerConfig(
          name=s.name,
          transport=@transport.AnyTransport::StdioClient(
            @transport.StdioClientTransport::StdioClientTransport(
              cmd=s.command,
              args=s.args,
              extra_env~,
            ),
          ),
          auth=@mcp.ServerAuth::NoAuth,
        ),
      )
    }
    Http(s) => {
      let mut auth_token = ""
      let extra_headers : Array[(String, String)] = []
      let mut saw_authorization = false
      for header in s.headers {
        if header.name == "Authorization" && !saw_authorization {
          auth_token = strip_bearer_prefix(header.value)
          saw_authorization = true
        } else if header.name != "" {
          extra_headers.push((header.name, header.value))
        }
      }
      Ok(
        @mcp.MCPServerConfig::MCPServerConfig(
          name=s.name,
          transport=@transport.AnyTransport::HttpClient(
            @transport.HttpClientTransport::HttpClientTransport(
              s.url,
              auth_token~,
              extra_headers~,
            ),
          ),
          auth=@mcp.ServerAuth::NoAuth,
        ),
      )
    }
    Sse(s) =>
      Err(
        "MCP server '\{@devkit.sanitize_label(s.name)}': sse transport is not supported (stdio and http only)",
      )
  }
}

///|
/// True when two configs dial the same transport endpoint: http compares
/// `base_url`, stdio compares `command` — both case-sensitive, and args /
/// env / headers are not part of the identity. Different transports are
/// never the same server. Names are not compared: a same-name conflict with
/// a different endpoint shadows through the host's union filter instead.
fn same_server(a : @mcp.MCPServerConfig, b : @mcp.MCPServerConfig) -> Bool {
  match (a.transport, b.transport) {
    (
      @transport.AnyTransport::HttpClient(x),
      @transport.AnyTransport::HttpClient(y),
    ) => x.base_url == y.base_url
    (
      @transport.AnyTransport::StdioClient(x),
      @transport.AnyTransport::StdioClient(y),
    ) => x.cmd == y.cmd
    _ => false
  }
}

///|
/// Declaration indexes of header entries the mapping cannot carry (empty
/// header names), so the host can warn instead of silently discarding them.
fn acp_invalid_headers(server : @acp.McpServer) -> Array[Int] {
  match server {
    Http(s) => {
      let invalid : Array[Int] = []
      for i, header in s.headers {
        if header.name.is_empty() {
          invalid.push(i)
        }
      }
      invalid
    }
    _ => []
  }
}
