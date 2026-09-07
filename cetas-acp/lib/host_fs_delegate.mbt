///|
/// host_fs_delegate.mbt — `CETAS_DELEGATE_FS=host` workspace delegation.
///
/// When the knob selects `host`, the session's tool-facing `WorkspaceFs` is
/// an `AcpDelegateFs`: file reads and writes ride the ACP reverse calls
/// (`fs/read_text_file` / `fs/write_text_file`). Everything else stays
/// local — ACP v1 exposes only those two file text calls. Host-owned
/// persistence (settings, credentials, sidecars) never delegates. A failed
/// reverse call warns on stderr and retries locally; `host` is an explicit
/// opt-in, so availability wins.

///|
priv enum DelegateFsMode {
  Local
  Host
}

///|
fn parse_delegation_mode(raw : String) -> DelegateFsMode? {
  match raw {
    "local" => Some(DelegateFsMode::Local)
    "host" => Some(DelegateFsMode::Host)
    _ => None
  }
}

///|
/// Unset means `local`; an unrecognized value falls back to `local` with
/// one warning (the `CETAS_PERMISSION_MODE` tolerance — a typo never
/// widens the posture).
async fn resolve_startup_delegation_mode(
  env_value : String?,
) -> DelegateFsMode noraise {
  match env_value {
    None => DelegateFsMode::Local
    Some(raw) =>
      match parse_delegation_mode(raw) {
        Some(mode) => mode
        None => {
          acp_warn(
            "cetas-acp: CETAS_DELEGATE_FS '" +
            raw +
            "' is not one of local/host; using local\n",
          )
          DelegateFsMode::Local
        }
      }
  }
}

///|
async fn startup_delegation_mode() -> DelegateFsMode noraise {
  resolve_startup_delegation_mode(read_env_var("CETAS_DELEGATE_FS"))
}

///|
/// WorkspaceFs adapter for `CETAS_DELEGATE_FS=host`: file reads and writes
/// go to the attached ACP client, everything else passes through to the
/// wrapped local filesystem. Created as a shell at session assembly (no
/// client context yet); the host mirrors the invocation context onto it at
/// every attach point through the same helper that stamps
/// `SessionHandle.context`. Reads and writes outside an attached turn
/// (assembly-time discovery, post-retirement) therefore run locally by
/// design.
priv struct AcpDelegateFs {
  local_fs : &@workspace.WorkspaceFs
  session_id : String
  mut context : @acp.AgentContext?
}

///|
fn AcpDelegateFs::AcpDelegateFs(
  local_fs~ : &@workspace.WorkspaceFs,
  session_id~ : String,
) -> AcpDelegateFs {
  { local_fs, session_id, context: None, }
}

///|
fn AcpDelegateFs::attach(
  self : AcpDelegateFs,
  context~ : @acp.AgentContext,
) -> Unit {
  self.context = Some(context)
}

///|
fn AcpDelegateFs::detach(self : AcpDelegateFs) -> Unit {
  self.context = None
}

///|
fn delegate_error_text(error : @acp.AgentContextError) -> String {
  match error {
    AgentContextUnavailable(method_name~) => "unavailable: \{method_name}"
    AgentContextCancelled(method_name~) => "cancelled: \{method_name}"
    AgentContextBrokerFailure(method_name~) => "call failed: \{method_name}"
    AgentContextReplyMismatch(method_name~) =>
      "undecodable reply: \{method_name}"
  }
}

///|
async fn AcpDelegateFs::fallback_read(
  self : AcpDelegateFs,
  path : String,
  error : @acp.AgentContextError,
) -> String raise @workspace.WorkspaceFsError {
  acp_warn(
    "cetas-acp: fs/read_text_file delegation failed (session=" +
    self.session_id +
    ", path=" +
    path +
    "): " +
    delegate_error_text(error) +
    "; falling back to the local filesystem\n",
  )
  self.local_fs.read_file(path)
}

///|
async fn AcpDelegateFs::fallback_write(
  self : AcpDelegateFs,
  path : String,
  content : String,
  error : @acp.AgentContextError,
) -> Unit raise @workspace.WorkspaceFsError {
  acp_warn(
    "cetas-acp: fs/write_text_file delegation failed (session=" +
    self.session_id +
    ", path=" +
    path +
    "): " +
    delegate_error_text(error) +
    "; falling back to the local filesystem\n",
  )
  self.local_fs.write_file(path, content)
}

///|
impl @workspace.WorkspaceFs for AcpDelegateFs with fn read_file(self, path) {
  match self.context {
    Some(context) => {
      let params : @acp.ReadTextFileParams = {
        session_id: self.session_id,
        path,
        line: Omitted,
        limit: Omitted,
        meta: Omitted,
      }
      let result = context.read_text_file(params) catch {
        error => return self.fallback_read(path, error)
      }
      result.content
    }
    None => self.local_fs.read_file(path)
  }
}

///|
impl @workspace.WorkspaceFs for AcpDelegateFs with fn write_file(
  self,
  path,
  content,
) {
  match self.context {
    Some(context) => {
      let params : @acp.WriteTextFileParams = {
        session_id: self.session_id,
        path,
        content,
        meta: Omitted,
      }
      let _ = context.write_text_file(params) catch {
        error => return self.fallback_write(path, content, error)
      }
    }
    None => self.local_fs.write_file(path, content)
  }
}

///|
impl @workspace.WorkspaceFs for AcpDelegateFs with fn exists(self, path) {
  self.local_fs.exists(path)
}

///|
impl @workspace.WorkspaceFs for AcpDelegateFs with fn kind(
  self,
  path,
  follow_symlink~,
) {
  self.local_fs.kind(path, follow_symlink~)
}

///|
/// Atomic writes stay local: ACP has no atomic write call, and the
/// consumers (credentials, sidecars) are host-owned anyway.
impl @workspace.WorkspaceFs for AcpDelegateFs with fn write_file_atomic(
  self,
  path,
  content,
) {
  self.local_fs.write_file_atomic(path, content)
}

///|
impl @workspace.WorkspaceFs for AcpDelegateFs with fn remove(self, path) {
  self.local_fs.remove(path)
}

///|
impl @workspace.WorkspaceFs for AcpDelegateFs with fn rename(
  self,
  from,
  to_,
  replace~,
) {
  self.local_fs.rename(from, to_, replace~)
}

///|
impl @workspace.WorkspaceFs for AcpDelegateFs with fn realpath(self, path) {
  self.local_fs.realpath(path)
}

///|
impl @workspace.WorkspaceFs for AcpDelegateFs with fn readdir(
  self,
  path,
  include_hidden~,
) {
  self.local_fs.readdir(path, include_hidden~)
}

///|
impl @workspace.WorkspaceFs for AcpDelegateFs with fn walk(self, root, callback) {
  self.local_fs.walk(root, callback)
}

///|
impl @workspace.WorkspaceFs for AcpDelegateFs with fn mkdir(
  self,
  path,
  recursive~,
) {
  self.local_fs.mkdir(path, recursive~)
}
