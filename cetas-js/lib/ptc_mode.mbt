///|
/// Host-side PTC mode bridge. The runtime stays in posoco-ext-bunraku; this adapter
/// belongs to Cetas because its model-facing catalog combines base, Pi and MCP
/// tools and its terminal owns the interactive picker.
pub(all) enum CetasPtcStatus {
  PtcDirect
  PtcHybrid
  PtcOnly
} derive(Eq, Debug)

///|
pub extend CetasPtcStatus with Eq::{not_equal, equal}

///|
pub extend CetasPtcStatus with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub struct CetasPtcMode {
  bus : @devkit.EventBus?
  mut current_ : CetasPtcStatus
  mut revision_ : Int32
}

///|
pub fn CetasPtcMode::CetasPtcMode(
  bus~ : @devkit.EventBus? = None,
) -> CetasPtcMode {
  let self = { bus, current_: PtcHybrid, revision_: 0, }
  // The statusbar is already subscribed when the host composes this mode.
  self.publish_status()
  self
}

///|
pub fn CetasPtcMode::mode(self : CetasPtcMode) -> CetasPtcStatus {
  self.current_
}

///|
pub fn CetasPtcMode::revision(self : CetasPtcMode) -> Int32 {
  self.revision_
}

///|
fn CetasPtcMode::mode_name(self : CetasPtcMode) -> String {
  match self.current_ {
    PtcDirect => "off"
    PtcHybrid => "hybrid"
    PtcOnly => "on"
  }
}

///|
fn CetasPtcMode::status_json(self : CetasPtcMode) -> Json {
  Json::object({
    "mode": Json::string(self.mode_name()),
    "revision": Json::number(self.revision_.to_double()),
  })
}

///|
fn CetasPtcMode::publish_status(self : CetasPtcMode) -> Unit {
  match self.bus {
    None => ()
    Some(bus) =>
      match self.current_ {
        PtcDirect =>
          @devkit.publish_status_unregister(
            bus,
            source="posoco_ext_bunraku",
            segment="ptc",
          )
        PtcHybrid =>
          @devkit.publish_status_register(
            bus,
            source="posoco_ext_bunraku",
            segment="ptc",
            priority=11,
            value="Hybrid",
            color="muted",
          )
        PtcOnly =>
          @devkit.publish_status_register(
            bus,
            source="posoco_ext_bunraku",
            segment="ptc",
            priority=11,
            value="PTC",
            color="accent",
          )
      }
  }
}

///|
/// Visibility is a declarative projection now: the kernel narrows each
/// captured definition by this hook (hooks can only narrow, never widen).
/// `off` withdraws the transport itself; `on` folds the nested face —
/// owners taken from bunraku's single `tool_call_owners` source, the same
/// list the kernel enforces for guest calls — into `Deferred`: not offered
/// to the model, still callable by approved programs. The old `model_sees`
/// name filter and the PtcOnly `before_tool` rejection are retired; the
/// kernel's `NotExecuted(NotOffered)` covers a model that emits a
/// remembered name.
pub impl @posoco.PipelineHook for CetasPtcMode with fn tool_exposure(
  self : CetasPtcMode,
  definition : @posoco.ToolDef,
) -> @posoco.ToolExposure {
  let name = definition.name.to_string()
  match self.current_ {
    PtcDirect =>
      if name == "run_code" {
        @posoco.ToolExposure::Disabled
      } else {
        definition.exposure
      }
    PtcHybrid => definition.exposure
    PtcOnly =>
      if name == "run_code" {
        definition.exposure
      } else if @bunraku.bunraku_nested_source_owners().contains(
          definition.owner.to_string(),
        ) {
        @posoco.ToolExposure::Deferred
      } else {
        definition.exposure
      }
  }
}

///|
/// Idempotent mode changes only produce an event and catalog revision when
/// the effective mode actually changes.
pub fn CetasPtcMode::set(self : CetasPtcMode, next : CetasPtcStatus) -> Unit {
  if self.current_ != next {
    self.current_ = next
    self.revision_ += 1
    self.publish_status()
  }
}

///|
pub impl @posoco.Extension for CetasPtcMode with fn extension_id(_self) -> String {
  "cetas_ptc_mode"
}

///|
pub impl @posoco.Extension for CetasPtcMode with fn manifest(self) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="cetas_ptc_mode", commands=[self], hooks=[self])
}

///|
pub impl @posoco.CommandPort for CetasPtcMode with fn commands(_self) -> Array[
  @posoco.CommandDef,
] {
  [
    @posoco.CommandDef::{
      id: "ptc",
      label: "PTC Mode",
      description: "Select direct, hybrid or programmatic tool calling",
      category: "ptc",
      ctype: @posoco.CommandType::Select,
      params: [
        @posoco.CommandParam::{
          name: "action",
          label: "Mode",
          description: "on / hybrid / off / status (no argument opens the picker in Cetas)",
          ptype: @posoco.ParamType::Str,
          required: false,
          default: None,
          choices: Some(["on", "hybrid", "off", "status"]),
          positional: true,
        },
      ],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
  ]
}

///|
fn ptc_command_action(args : Json) -> String? raise @posoco.CommandError {
  match args {
    Json::Null => None
    String(value) => if value == "" { None } else { Some(value) }
    Object(fields) =>
      match fields.get("action") {
        None | Some(Json::Null) => None
        Some(String(value)) => if value == "" { None } else { Some(value) }
        Some(_) =>
          raise @posoco.CommandError::InvalidArgs(
            reason="/ptc action must be a string",
          )
      }
    _ =>
      raise @posoco.CommandError::InvalidArgs(
        reason="/ptc expects on, hybrid, off or status",
      )
  }
}

///|
pub impl @posoco.CommandPort for CetasPtcMode with fn invoke(
  self,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  if id != "ptc" {
    raise @posoco.CommandError::NotFound(id)
  }
  match ptc_command_action(args) {
    None =>
      @posoco.CommandOutcome::NeedsInput(
        prompt="Choose a PTC mode with /ptc on, /ptc hybrid or /ptc off",
      )
    Some("status") =>
      @posoco.CommandOutcome::Success(
        feedback="PTC mode: " + self.mode_name(),
        structured=Some(self.status_json()),
        ui_hint=None,
      )
    Some(action) if action == "on" || action == "off" || action == "hybrid" => {
      let next = match action {
        "on" => PtcOnly
        "off" => PtcDirect
        _ => PtcHybrid
      }
      self.set(next)
      @posoco.CommandOutcome::Success(
        feedback="PTC mode: " + self.mode_name() + " (effective on next turn)",
        structured=Some(self.status_json()),
        ui_hint=Some(@posoco.UiHint::Toast),
      )
    }
    Some(other) =>
      @posoco.CommandOutcome::Failure(
        reason="unknown PTC mode '" +
          other +
          "' (expected on/hybrid/off/status)",
      )
  }
}

///|
/// SystemPromptContributor is cached by Posoco on the first turn. Put the
/// *dynamic* instructions in a PipelineHook, as Plan Mode does.
fn CetasPtcMode::mode_guidance(self : CetasPtcMode) -> String {
  match self.current_ {
    PtcDirect =>
      "PTC is off. run_code is not available. Use the declared native tools."
    PtcHybrid =>
      "PTC is hybrid. Native tools and run_code are available. Use run_code only for predictable batches whose intermediate results can stay out of context."
    PtcOnly =>
      "PTC Only is active. Use run_code for read/search/write/edit/bash operations exposed through ctx.call. Only the tool owners run_code declares (read/grep/glob/write/edit/bash) fold into it; every other tool remains directly callable. Do not assume run_code bypasses plan mode or permission policy."
  }
}

///|
pub impl @posoco.PipelineHook for CetasPtcMode with fn before_model(
  self,
  messages : Array[@posoco.Message],
) -> Array[@posoco.Message] raise @posoco.HookAbort {
  let content = @devkit.context_envelope(
    ns="ptc",
    kind="mode",
    trust=true,
    content=self.mode_guidance(),
  )
  for index, message in messages {
    match message {
      @posoco.Message::UserMessage(content=blocks) =>
        if blocks
          .iter()
          .any(fn(block) {
            match block {
              @posoco.Content::Text(value) => value.has_prefix("<ptc-context")
              _ => false
            }
          }) {
          messages[index] = @posoco.Message::UserMessage(content=[
            @posoco.Content::Text(content),
          ])
          return messages
        }
      _ => ()
    }
  }
  messages.push(
    @posoco.Message::UserMessage(content=[@posoco.Content::Text(content)]),
  )
  messages
}

///|
pub extend CetasPtcMode with @posoco.Extension::{manifest, extension_id}

///|
pub extend CetasPtcMode with @posoco.CommandPort::{commands, invoke}

///|
pub extend CetasPtcMode with @posoco.PipelineHook::{
  on_post_event,
  on_turn_begin,
  before_model,
  before_tool,
  tool_exposure,
  on_turn_end,
}
