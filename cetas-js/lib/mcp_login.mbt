///|
/// mcp_login.mbt — host-side OAuth orchestration for MCP servers.
///
/// `mcp_login_flow` is the interactive chain behind `/mcp login`: from a
/// captured 401 challenge, RFC 9728/8414 metadata discovery, RFC 7591 dynamic
/// registration, RFC 8628 device flow, then persist the credential (with the
/// endpoints a later refresh needs) and reconnect the server with the fresh
/// access token. `mcp_inject_stored_tokens` is the composition-time pass:
/// inject stored tokens, refreshing expired ones first. Both are plain
/// functions over the bridge + store + transport seams so the e2e test drives
/// exactly what the host drives.

///|
/// Provider id convention for one MCP server's stored credential.
fn mcp_provider_id(server : String) -> String {
  "mcp." + server
}

///|
/// The MCP login credential store below the cetas home. A separate root from
/// the provider credentials (`~/.cetas/credentials`): MCP server tokens are
/// their own seam and can be revoked wholesale by deleting the directory.
fn mcp_credential_store(
  fs : &@workspace.WorkspaceFs,
  home : String,
) -> @credentials.FileProviderCredentialStore {
  @credentials.FileProviderCredentialStore(fs, home + "/.cetas/mcp-credentials")
}

///|
/// Copy of `credential` whose metadata carries the two keys a later
/// non-interactive refresh needs (`token_endpoint`, `client_id`). Other
/// metadata keys survive.
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
/// Caller-facing text for an OAuth error. The oauth package's Show impl is
/// not public, and Debug reprs leak constructor noise — an explicit variant
/// map keeps messages bounded and sanitizes any inner detail.
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

///|
/// Interactive login for one MCP server, end to end. Every failure folds
/// into a sanitized `Err` naming the server (never a token); on success the
/// access token is injected and the server reconnected, so its tools are
/// available in the same command.
async fn mcp_login_flow(
  bridge : @mcp.MCPToolBridge,
  server : String,
  store : &@oauth.ProviderCredentialStore,
  transport : &@oauth.OAuthHttpTransport,
  interaction : &@oauth.AuthInteraction,
  now_secs : Int,
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
    registration_endpoint, "cetas-js", transport,
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
    mcp_provider_id(server),
    @oauth.ProviderCredential::OAuth(credential),
  ) catch {
    _ => return Err("credential store write failed for server '" + label + "'")
  }
  // The device flow stamps expires_at from its own clock; the host's
  // now_secs is only the caller's reference time, not used for the decision.
  ignore(now_secs)
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
/// connects. Any per-server failure just skips that server — activation then
/// records the 401 for `/mcp` and the user re-runs login; composition must
/// never fail here.
async fn mcp_inject_stored_tokens(
  bridge : @mcp.MCPToolBridge,
  store : &@oauth.ProviderCredentialStore,
  transport : &@oauth.OAuthHttpTransport,
  now_secs : Int,
) -> Unit noraise {
  for server in bridge.servers_by_auth(@mcp.ServerAuth::OAuth) {
    inject_stored_token_one(bridge, store, transport, server, now_secs) catch {
      _ => ()
    }
  }
}

///|
async fn inject_stored_token_one(
  bridge : @mcp.MCPToolBridge,
  store : &@oauth.ProviderCredentialStore,
  transport : &@oauth.OAuthHttpTransport,
  server : String,
  now_secs : Int,
) -> Unit {
  let credential = match store.read(mcp_provider_id(server)) {
    Some(@oauth.ProviderCredential::OAuth(credential)) => credential
    // No record, or an ApiKey record (not this seam's credential kind).
    _ => return
  }
  let token : String = if !credential.is_expired(now_secs) {
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
          // Refresh failed: leave the server anonymous for this session.
          // The 401 surfaces in `/mcp`; the user re-runs login.
          _ => return
        }
        let updated = with_refresh_endpoints(
          refreshed,
          token_endpoint~,
          client_id~,
        )
        store.write(
          mcp_provider_id(server),
          @oauth.ProviderCredential::OAuth(updated),
        ) catch {
          // Persisting the rotated credential failed; the in-memory token is
          // still injected — worst case the next start refreshes again.
          _ => ()
        }
        updated.access_token
      }
      // Expired with no refresh endpoints on record (the record predates
      // login storing them): inject the stale token and let the server rule
      // on it — skipping would lock out a session we cannot replace without
      // interaction anyway.
      _ => credential.access_token
    }
  }
  bridge.set_server_token(server, token)
}
