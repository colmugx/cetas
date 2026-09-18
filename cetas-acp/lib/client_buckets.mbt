///|
/// client_buckets.mbt — per-client session storage. The ACP client owns
/// chat-record management; the host persists transcripts only to trade disk
/// for memory (nothing accumulates in RAM beyond the live sessions), and
/// files land in a directory named after the client that drove the session:
/// `<home>/.cetas/sessions/<client>/cetas-<id>.jsonl`. A client sending none
/// of the identity signals (initialize clientInfo name, `_meta.client`,
/// known injected host server) shares the `acp` bucket.

///|
/// The connecting client's `initialize.clientInfo.name`; `None` when the
/// client sent no clientInfo (or an empty name), so the caller falls through
/// to the next signal. Always set before any session handler: the protocol
/// requires initialize first.
fn client_name_of(context : @acp.AgentContext) -> String? {
  match (context.client_info)() {
    Value(info) if info.name.length() > 0 => Some(info.name)
    _ => None
  }
}

///|
/// The `_meta.client` string sanitized into a directory name; `None` when
/// the name carries nothing usable, so the caller falls through to the next
/// signal instead of minting an empty directory name.
fn meta_client_slug(meta : @acp.ProtocolNullable[Json]) -> String? {
  match meta {
    Value(Json::Object(fields)) =>
      match fields.get("client") {
        Some(Json::String(name)) => client_bucket_slug(name)
        _ => None
      }
    _ => None
  }
}

///|
fn client_bucket_slug(name : String) -> String? {
  let slug = @devkit.sanitize_label(name.trim().to_owned(), limit=48).to_lower()
  if slug.length() == 0 {
    None
  } else {
    Some(slug)
  }
}

///|
/// Which client bucket a request's sessions belong in, in priority order:
/// the initialize clientInfo name, then an explicit `_meta.client`, then the
/// injected-host heuristic (the same lody/paseo server names that pick the
/// host profile), else `acp`. The client name goes through
/// `client_bucket_slug` too, so an empty name falls through like `None`.
fn resolve_client_bucket(
  client_name : String?,
  meta : @acp.ProtocolNullable[Json],
  mcp_servers : Array[@acp.McpServer],
) -> String {
  let from_client = match client_name {
    Some(name) => client_bucket_slug(name)
    None => None
  }
  match from_client {
    Some(slug) => slug
    None =>
      match meta_client_slug(meta) {
        Some(slug) => slug
        None =>
          match detect_host_kind(acp_mcp_server_names(mcp_servers)) {
            Lody => "lody"
            Paseo => "paseo"
            Generic => "acp"
          }
      }
  }
}

///|
fn client_sessions_dir(home : String, bucket : String) -> String {
  @cetas_core.sessions_dir(home) + "/" + bucket
}

///|
/// The bucket directory holding a session's persisted transcript, for
/// `session/resume`: the bucket this request resolves to first (the common
/// same-client reconnect), then every directory under the sessions root (a
/// resume through a differently-identifying client still finds its file).
/// `None` when no bucket carries the id — the client's record list is the
/// authority, so a miss simply rebuilds an empty session.
async fn CetasAcpHost::find_session_bucket(
  self : CetasAcpHost,
  session_id : String,
  client_name : String?,
  meta : @acp.ProtocolNullable[Json],
  mcp_servers : Array[@acp.McpServer],
) -> String? noraise {
  match @fs_session.validate_session_id(session_id) {
    Ok(_) => ()
    Err(_) => return None
  }
  let resolved = client_sessions_dir(
    self.home,
    resolve_client_bucket(client_name, meta, mcp_servers),
  )
  let candidates : Array[String] = [resolved]
  let root = @cetas_core.sessions_dir(self.home)
  let entries : Array[String] = self.fs.readdir(root, include_hidden=false) catch {
    _ => []
  }
  for entry in entries {
    let dir = root + "/" + entry
    if dir != resolved {
      candidates.push(dir)
    }
  }
  for dir in candidates {
    let has_history = self.fs.exists(
      @fs_session.jsonl_session_path(dir, session_id),
    ) catch {
      _ => false
    }
    if has_history {
      return Some(dir)
    }
  }
  None
}
