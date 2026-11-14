///|
/// Native Pi guest tools are ordinary Posoco contributions. A Go-hosted
/// JavaScript VM executes foreign closures; it NEVER owns the Agent run loop,
/// permissions, model requests, catalog snapshots or session journal.
///
/// Each Agent gets a separate contribution owner and request/response inbox.
/// This extension is present only in the native terminal composition.
const NATIVE_PI_OWNER : String = "cetas_native_pi_guest"

///|
pub struct NativePiGuest {
  session_id : String
  hub : EventHub
  mut contributions : @posoco.ToolContributions?
  mut next_id : Int32
  pending : Map[String, @aqueue.Queue[Json]]
  mut defs : Array[@posoco.ToolDef]
}

///|
pub fn NativePiGuest::new(session_id : String, hub : EventHub) -> NativePiGuest {
  {
    session_id,
    hub,
    contributions: None,
    next_id: 0,
    pending: Map::from_array([]),
    defs: [],
  }
}

///|
pub impl @posoco.Extension for NativePiGuest with fn extension_id(
  _ : NativePiGuest,
) -> String {
  NATIVE_PI_OWNER
}

///|
pub impl @posoco.Extension for NativePiGuest with fn manifest(
  self : NativePiGuest,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id=NATIVE_PI_OWNER,
    tools=[self],
    lifecycle=[self as &@posoco.Lifecycle],
    requires=[@posoco.Capability::ToolContribution],
  )
}

///|
pub impl @posoco.Lifecycle for NativePiGuest with fn on_compose(
  self : NativePiGuest,
  view : @posoco.CompositionView,
) -> Unit raise @posoco.CompositionError {
  self.contributions = view.tool_contributions()
}

///|
pub impl @posoco.ToolProvider for NativePiGuest with fn list_tools(
  _ : NativePiGuest,
) -> Array[@posoco.ToolDef] {
  // The static manifest is deliberately empty. Only the authenticated Go
  // host can publish guest definitions after composition.
  []
}

///|
pub impl @posoco.ToolProvider for NativePiGuest with fn execute(
  self : NativePiGuest,
  ctx : @posoco.ToolCallContext,
) -> @kernel.ToolOutcome raise @posoco.RuntimeError {
  self.execute_guest(ctx) catch {
    error =>
      @kernel.RuntimeFailure(
        error_category="PiGuest",
        message=error.to_string(),
      )
  }
}

///|
priv struct NativePiPinnedTools {
  defs : Array[@posoco.ToolDef]
  guest : NativePiGuest
}

///|
impl @posoco.ToolProvider for NativePiPinnedTools with fn list_tools(
  self : NativePiPinnedTools,
) -> Array[@posoco.ToolDef] {
  self.defs.copy()
}

///|
impl @posoco.ToolProvider for NativePiPinnedTools with fn execute(
  self : NativePiPinnedTools,
  ctx : @posoco.ToolCallContext,
) -> @kernel.ToolOutcome raise @posoco.RuntimeError {
  self.guest.execute_guest(ctx) catch {
    error =>
      @kernel.RuntimeFailure(
        error_category="PiGuest",
        message=error.to_string(),
      )
  }
}

///|
async fn NativePiGuest::execute_guest(
  self : NativePiGuest,
  ctx : @posoco.ToolCallContext,
) -> @kernel.ToolOutcome {
  // A unique per-session request ID. The Go host never sees or holds
  // MoonBit-owned pointers, only a copied JSON EventHub frame.
  self.next_id += 1
  let request_id = self.session_id + ":pi:" + self.next_id.to_string()
  let reply : @aqueue.Queue[Json] = Queue(kind=Blocking(1))
  self.pending[request_id] = reply
  self.hub.emit_out_of_band(self.session_id, "pi.guest.execute", extra=[
    ("request_id", Json::string(request_id)),
    ("tool_name", Json::string(ctx.name.to_string())),
    ("call_id", Json::string(ctx.call_id.to_string())),
    ("arguments", ctx.arguments),
  ])
  let outcome = reply.get() catch {
    error => {
      self.pending.remove(request_id)
      return @kernel.RuntimeFailure(
        error_category="PiGuestCancelled",
        message=error.to_string(),
      )
    }
  }
  self.pending.remove(request_id)
  match outcome {
    Json::Object(fields) => {
      let text = match fields.get("content") {
        Some(Json::String(value)) => value
        _ => ""
      }
      let structured = match fields.get("details") {
        Some(Json::Null) | None => None
        Some(value) => Some(value)
      }
      match fields.get("ok") {
        Some(Json::True) => @kernel.Success(content=text, structured~)
        _ => @kernel.ToolReportedError(content=text, structured~)
      }
    }
    _ =>
      @kernel.RuntimeFailure(
        error_category="PiGuestProtocol",
        message="guest returned a non-object result",
      )
  }
}

///|
/// A stale, duplicate or cross-session reply cannot change the Agent.
fn NativePiGuest::resolve(
  self : NativePiGuest,
  request_id : String,
  outcome : Json,
) -> Bool {
  match self.pending.get(request_id) {
    Some(queue) => queue.try_put(outcome) catch { _ => false }
    None => false
  }
}

///|
/// Normalize guest tool descriptors without loosening their TypeBox/JSON
/// Schema constraints. The Kernel validates the resulting ToolDefs.
fn native_pi_defs(tools : Json) -> Result[Array[@posoco.ToolDef], String] {
  guard tools is Json::Array(items) else {
    return Err("Pi tool catalog must be an array")
  }
  if items.length() > 128 {
    return Err("Pi tool catalog is too large (limit 128)")
  }
  let defs : Array[@posoco.ToolDef] = []
  let seen : Map[String, Bool] = Map::from_array([])
  for item in items {
    guard item is Json::Object(fields) else {
      return Err("Pi tool must be an object")
    }
    let name = match fields.get("name") {
      Some(Json::String(name)) if !name.is_empty() => name
      _ => return Err("Pi tool needs a nonempty name")
    }
    if seen.contains(name) {
      return Err("duplicate Pi tool name: " + name)
    }
    seen[name] = true
    let description = match fields.get("description") {
      Some(Json::String(value)) => value
      _ => ""
    }
    let schema = fields
      .get("parameters")
      .unwrap_or(
        Json::object({
          "type": Json::string("object"),
          "properties": Json::object(Map::from_array([])),
        }),
      )
    defs.push(
      @posoco.ToolDef(
        name=@posoco.ToolName::unchecked(name),
        description~,
        input_schema=schema,
        owner=@posoco.OwnerId::unchecked(NATIVE_PI_OWNER),
        // One JS VM per guest session; concurrent calls are serialized there.
        policy=@posoco.ExecutionPolicy::Sequential,
        provenance=Some("pi-native"),
      ),
    )
  }
  Ok(defs)
}

///|
/// Publish a snapshot for the next admitted Posoco operation. This is
/// owner-bound and atomically validated by the same Kernel tool directory
/// as every other extension (including the JS surface).
pub async fn NativePiGuest::install(
  self : NativePiGuest,
  tools : Json,
) -> Result[Unit, String] {
  let defs = match native_pi_defs(tools) {
    Ok(defs) => defs
    Err(reason) => return Err(reason)
  }
  let handle = match self.contributions {
    Some(handle) => handle
    None => return Err("Native Pi tool contribution was not composed")
  }
  let provider = NativePiPinnedTools::{ defs, guest: self, }
  let provider = provider as &@posoco.ToolProvider
  match handle.replace(provider~) {
    Ok(_) => {
      self.defs = defs
      Ok(())
    }
    Err(error) => Err(error.to_string())
  }
}

///|
/// Withdraw the owner's dynamic group on retirement; queued callers already
/// have a scoped response slot and are cancelled by the owning Agent.
pub async fn NativePiGuest::retire(self : NativePiGuest) -> Unit {
  match self.contributions {
    Some(handle) => {
      let _ = handle.withdraw()
      ()
    }
    None => ()
  }
  self.pending.clear()
}

///|
pub extend NativePiGuest with @posoco.Extension::{extension_id, manifest}

///|
pub extend NativePiGuest with @posoco.Lifecycle::{
  on_compose,
  on_start,
  on_shutdown,
}

///|
pub extend NativePiGuest with @posoco.ToolProvider::{list_tools, execute}
