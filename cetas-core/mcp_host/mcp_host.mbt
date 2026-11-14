///|
/// Cetas-side MCP host glue, shared by every host so a login or a token refresh
/// behaves identically everywhere: the Cetas-owned facts (where a server
/// credential lives, which client name registers) and the OAuth flow itself —
/// metadata discovery, dynamic registration, device flow, persistence and the
/// reconnecting call.
///
/// The flow sits here rather than next to the bridge because the extension's
/// colmugx/mcp still pins `moonbitlang/async`; until that upstream
/// `TaskGroup` no longer unifies with the core-async group it passes to the MCP
/// SDK; one shared implementation here still beats a copy per host. Moving it
/// upstream only needs that dependency alignment.
///
/// The credential root is deliberately separate from the provider credentials:
/// MCP server tokens are their own seam and can be revoked wholesale by
/// deleting the directory.

///|
/// Credential store for MCP server OAuth tokens under the Cetas home.
pub fn cetas_mcp_credential_store(
  fs : &@workspace.WorkspaceFs,
  home : String,
) -> @credentials.FileProviderCredentialStore {
  @credentials.FileProviderCredentialStore(fs, home + "/.cetas/mcp-credentials")
}

///|
/// The client name Cetas registers with an authorization server. Shared by every
/// host so a login performed in one terminal is the same client in another.
pub fn cetas_mcp_oauth_client_name() -> String {
  "cetas"
}

///|
/// Interactive OAuth login for one MCP server, with the Cetas store and client
/// name filled in. `interaction` is the host's UI port for the device code.
pub async fn cetas_mcp_login(
  bridge : @mcp.MCPToolBridge,
  server : String,
  fs : &@workspace.WorkspaceFs,
  home : String,
  transport : &@oauth.OAuthHttpTransport,
  interaction : &@oauth.AuthInteraction,
) -> Result[String, String] noraise {
  mcp_login(
    bridge,
    server,
    cetas_mcp_credential_store(fs, home),
    transport,
    interaction,
    client_name=cetas_mcp_oauth_client_name(),
  )
}

///|
/// Composition-time credential pass over every OAuth-declared server, with the
/// Cetas store filled in. `now_secs` is epoch seconds.
pub async fn cetas_mcp_inject_stored_tokens(
  bridge : @mcp.MCPToolBridge,
  fs : &@workspace.WorkspaceFs,
  home : String,
  transport : &@oauth.OAuthHttpTransport,
  now_secs : Int32,
) -> Unit noraise {
  mcp_inject_stored_tokens(
    bridge,
    cetas_mcp_credential_store(fs, home),
    transport,
    now_secs,
  )
}

///|
/// Interactive OAuth login for one MCP server: RFC 9728/8414 metadata
/// discovery, RFC 7591 dynamic registration, RFC 8628 device flow, credential
/// persistence and the reconnecting call.
///
/// Lives here rather than in the extension because the extension's own module
/// SDK migrates, `TaskGroup` does not unify with
/// unifies with the core-async group the bridge passes to the MCP SDK
/// (`MCPClient::connect_stdio`). Moving this glue upstream needs that alignment
/// first; until then one shared implementation here beats a copy per host.
pub async fn mcp_login(
  bridge : @mcp.MCPToolBridge,
  server : String,
  store : &@oauth.ProviderCredentialStore,
  transport : &@oauth.OAuthHttpTransport,
  interaction : &@oauth.AuthInteraction,
  client_name~ : String,
) -> Result[String, String] noraise {
  let label = @devkit.sanitize_label(server)
  // A 401 challenge is only recorded once a connection attempt ate it. With
  // none cached (e.g. login before the first activation), force one real
  // connection so the server can advertise its protected-resource metadata.
  let challenge = match bridge.auth_challenge(server) {
    Some(uri) => uri
    None => {
      let _ = bridge.reconnect_server(server) catch { _ => Ok(()) }
      match bridge.auth_challenge(server) {
        Some(uri) => uri
        None =>
          return Err(
            "no OAuth challenge from server '" +
            label +
            "' (does it require auth?)",
          )
      }
    }
  }
  let resource_md = @oauth.fetch_resource_metadata(challenge, transport) catch {
    err =>
      return Err("resource metadata discovery failed: " + oauth_error_text(err))
  }
  if resource_md.authorization_servers.length() == 0 {
    return Err("resource metadata listed no authorization servers")
  }
  let as_url = resource_md.authorization_servers[0]
  let server_md = @oauth.fetch_server_metadata(
    as_url + "/.well-known/oauth-authorization-server",
    transport,
  ) catch {
    err =>
      return Err(
        "authorization server metadata discovery failed: " +
        oauth_error_text(err),
      )
  }
  let registration_endpoint = match server_md.registration_endpoint {
    Some(endpoint) => endpoint
    None =>
      return Err(
        "authorization server metadata has no registration_endpoint (dynamic registration required)",
      )
  }
  let device_endpoint = match server_md.device_authorization_endpoint {
    Some(endpoint) => endpoint
    None =>
      return Err(
        "authorization server metadata has no device_authorization_endpoint",
      )
  }
  let client_id = @oauth.register_client(
    registration_endpoint, client_name, transport,
  ) catch {
    err =>
      return Err("dynamic client registration failed: " + oauth_error_text(err))
  }
  let flow_config = @oauth.DeviceFlowConfig::DeviceFlowConfig(
    client_id~,
    device_auth_endpoint=device_endpoint,
    token_endpoint=server_md.token_endpoint,
  )
  let issued = @oauth.run_device_flow_with_transport(
    flow_config, interaction, transport,
  ) catch {
    err => return Err("device flow failed: " + oauth_error_text(err))
  }
  let credential = with_refresh_endpoints(
    issued,
    token_endpoint=server_md.token_endpoint,
    client_id~,
  )
  store.write(
    mcp_credential_id(server),
    @oauth.ProviderCredential::OAuth(credential),
  ) catch {
    _ => return Err("credential store write failed for server '" + label + "'")
  }
  bridge.set_server_token(server, credential.access_token)
  let reconnected : Result[Unit, String] = bridge.reconnect_server(server) catch {
    _ => Err("reconnect aborted unexpectedly")
  }
  match reconnected {
    Err(message) =>
      Err(
        "login ok but reconnect failed for '" +
        label +
        "': " +
        @devkit.sanitize_label(message),
      )
    Ok(_) => {
      let prefix = "\{server}__"
      let mut tool_count = 0
      for tool in @posoco.ToolProvider::list_tools(bridge) {
        if tool.name.to_string().has_prefix(prefix) {
          tool_count = tool_count + 1
        }
      }
      let tool_word = if tool_count == 1 { "tool" } else { "tools" }
      Ok(
        "logged into '" +
        label +
        "'; " +
        tool_count.to_string() +
        " " +
        tool_word +
        " available",
      )
    }
  }
}

///|
/// Composition-time token injection for every OAuth-declared server: read the
/// stored credential, refresh it first when expired (persisting the rotated
/// one), and hand the access token to the bridge before lazy activation
/// connects. Any per-server failure just skips that server — activation records
/// the 401 and the user re-runs login; composition must never fail here.
pub async fn mcp_inject_stored_tokens(
  bridge : @mcp.MCPToolBridge,
  store : &@oauth.ProviderCredentialStore,
  transport : &@oauth.OAuthHttpTransport,
  now_secs : Int32,
) -> Unit noraise {
  for server in bridge.servers_by_auth(@mcp.ServerAuth::OAuth) {
    mcp_inject_stored_token_one(bridge, store, transport, server, now_secs) catch {
      _ => ()
    }
  }
}

///|
async fn mcp_inject_stored_token_one(
  bridge : @mcp.MCPToolBridge,
  store : &@oauth.ProviderCredentialStore,
  transport : &@oauth.OAuthHttpTransport,
  server : String,
  now_secs : Int32,
) -> Unit {
  let credential = match store.read(mcp_credential_id(server)) {
    Some(@oauth.ProviderCredential::OAuth(credential)) => credential
    _ => return
  }
  let token = if !credential.is_expired(now_secs) {
    credential.access_token
  } else {
    match
      (
        credential.metadata_value("token_endpoint"),
        credential.metadata_value("client_id"),
      ) {
      (Some(token_endpoint), Some(client_id)) => {
        let refreshed = @oauth.run_refresh_flow(
          token_endpoint~,
          client_id~,
          refresh_token=credential.refresh_token,
          transport~,
        ) catch {
          _ => return
        }
        let updated = with_refresh_endpoints(
          refreshed,
          token_endpoint~,
          client_id~,
        )
        store.write(
          mcp_credential_id(server),
          @oauth.ProviderCredential::OAuth(updated),
        ) catch {
          _ => ()
        }
        updated.access_token
      }
      // Expired with no refresh endpoints on record: inject the stale token and
      // let the server rule on it.
      _ => credential.access_token
    }
  }
  bridge.set_server_token(server, token)
}

///|
/// Namespace for one MCP server's stored credential.
pub fn mcp_credential_id(server : String) -> String {
  "mcp." + server
}

///|
/// Copy of `credential` carrying the two keys a later non-interactive refresh
/// needs (`token_endpoint`, `client_id`); other metadata keys survive.
fn with_refresh_endpoints(
  credential : @oauth.Credential,
  token_endpoint~ : String,
  client_id~ : String,
) -> @oauth.Credential {
  let metadata = credential.metadata.copy()
  metadata["token_endpoint"] = token_endpoint
  metadata["client_id"] = client_id
  { ..credential, metadata, }
}

///|
/// Caller-facing text for an OAuth error. The oauth package's Show impl is not
/// public, and Debug reprs leak constructor noise — an explicit variant map
/// keeps messages bounded and sanitizes any inner detail.
fn oauth_error_text(err : @oauth.OAuthError) -> String {
  match err {
    AuthPending => "authorization pending"
    SlowDown => "polling too fast (slow_down)"
    AccessDenied => "access denied"
    ExpiredToken => "device code expired"
    InvalidGrant => "invalid grant"
    HttpError(detail) => "http error: " + @devkit.sanitize_label(detail)
    ParseError(detail) => "parse error: " + @devkit.sanitize_label(detail)
    Cancelled => "cancelled"
  }
}
