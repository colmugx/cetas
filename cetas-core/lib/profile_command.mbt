///|
/// profile_command.mbt — `/profiles` and `/profile` commands.
///
/// /profiles     — interactive picker (UiRequest::Select) over saved profiles
/// /profile SUB  — load/save/delete a named profile
///
/// cetas-core owns the command semantics and UI contract; hosts inject file
/// IO via callbacks (cetas-core cannot import @fs / extern "js").

///|
/// One saved profile, surfaced as a selectable option.
pub(all) struct ProfileSpec {
  name : String // file stem, also the unique id
  label : String // display label (may differ from name)
}

///|
pub fn ProfileSpec::ProfileSpec(name : String) -> ProfileSpec {
  { name, label: name }
}

///|
pub fn ProfileSpec::with_label(name~ : String, label~ : String) -> ProfileSpec {
  { name, label }
}

///|
/// Commands for managing persisted agent configurations.
///
/// Hosts inject four callbacks so cetas-core stays IO-free:
///   - list_profiles()  → current profile names (reads the profile directory)
///   - on_load(name)    → apply a profile (host rebuilds Agent from stored config)
///   - on_save(name)    → persist current config under name
///   - on_delete(name)  → remove the stored profile
pub(all) struct ProfileCommand {
  ui : &@posoco.UiPort
  list_profiles : () -> Array[ProfileSpec]
  mut on_load : (String) -> Unit
  mut on_save : (String) -> Unit
  mut on_delete : (String) -> Unit
}

///|
pub fn ProfileCommand::ProfileCommand(
  ui : &@posoco.UiPort,
  list_profiles~ : () -> Array[ProfileSpec],
  on_load~ : (String) -> Unit,
  on_save~ : (String) -> Unit,
  on_delete~ : (String) -> Unit,
) -> ProfileCommand {
  { ui, list_profiles, on_load, on_save, on_delete }
}

///|
pub impl @posoco.CommandPort for ProfileCommand with fn commands(
  _self : ProfileCommand,
) -> Array[@posoco.CommandDef] {
  [
    @posoco.CommandDef::{
      id: "profiles",
      label: "Profiles",
      description: "Pick a saved profile to load",
      category: "config",
      ctype: @posoco.CommandType::Select,
      params: [],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
    @posoco.CommandDef::{
      id: "profile",
      label: "Profile",
      description: "Manage profiles: load, save, delete",
      category: "config",
      ctype: @posoco.CommandType::MultiStep,
      params: [
        @posoco.CommandParam::{
          name: "action",
          label: "Action",
          description: "load, save, or delete",
          ptype: @posoco.ParamType::Str,
          required: true,
          default: None,
          choices: Some(["load", "save", "delete"]),
          positional: true,
        },
        @posoco.CommandParam::{
          name: "name",
          label: "Profile Name",
          description: "The profile to operate on",
          ptype: @posoco.ParamType::Str,
          required: true,
          default: None,
          choices: None,
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
pub impl @posoco.CommandPort for ProfileCommand with fn invoke(
  self : ProfileCommand,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome {
  match id {
    "profiles" => {
      let specs = (self.list_profiles)()
      if specs.is_empty() {
        return @posoco.CommandOutcome::Failure(
          reason="no saved profiles — use /profile save <name> to create one",
        )
      }
      let labels : Array[String] = []
      for s in specs {
        labels.push(s.label)
      }
      let req : @posoco.UiRequest = @posoco.UiRequest::Select(
        prompt="Select profile",
        options=labels,
        default=Some(0),
      )
      let resp = self.ui.request(req) catch {
        _ =>
          return @posoco.CommandOutcome::Failure(
            reason="ui request failed (unsupported ui port?)",
          )
      }
      match resp {
        @posoco.UiResponse::Selected(i) =>
          if i >= 0 && i < specs.length() {
            let name = specs[i].name
            (self.on_load)(name)
            @posoco.CommandOutcome::Success(
              feedback="loaded profile: " + name,
              structured=None,
              ui_hint=Some(@posoco.UiHint::RefreshSettings),
            )
          } else {
            @posoco.CommandOutcome::Failure(
              reason="selected index out of range: " + i.to_string(),
            )
          }
        @posoco.UiResponse::Cancelled =>
          @posoco.CommandOutcome::Failure(reason="cancelled")
        _ =>
          @posoco.CommandOutcome::Failure(
            reason="unexpected ui response for select request",
          )
      }
    }
    "profile" => {
      let (action, name) = parse_profile_args(args)
      match action {
        Some(act) =>
          match name {
            Some(n) =>
              match act {
                "load" => {
                  (self.on_load)(n)
                  @posoco.CommandOutcome::Success(
                    feedback="loaded profile: " + n,
                    structured=None,
                    ui_hint=Some(@posoco.UiHint::RefreshSettings),
                  )
                }
                "save" => {
                  (self.on_save)(n)
                  @posoco.CommandOutcome::Success(
                    feedback="saved profile: " + n,
                    structured=None,
                    ui_hint=Some(@posoco.UiHint::None),
                  )
                }
                "delete" => {
                  (self.on_delete)(n)
                  @posoco.CommandOutcome::Success(
                    feedback="deleted profile: " + n,
                    structured=None,
                    ui_hint=Some(@posoco.UiHint::None),
                  )
                }
                other =>
                  @posoco.CommandOutcome::Failure(
                    reason="unknown action: " +
                      other +
                      " (expected load, save, or delete)",
                  )
              }
            None =>
              @posoco.CommandOutcome::Failure(
                reason="missing profile name — usage: /profile " +
                  act +
                  " <name>",
              )
          }
        None =>
          @posoco.CommandOutcome::Failure(
            reason="missing action — usage: /profile <load|save|delete> <name>",
          )
      }
    }
    other => @posoco.CommandOutcome::Failure(reason="unknown command: " + other)
  }
}

///|
/// Parse /profile args from JSON. Accepts:
///   {"action":"load","name":"coding-fast"}
///   {"_positional":"load coding-fast"}  (from host.ts slash parser)
fn parse_profile_args(args : Json) -> (String?, String?) {
  match args {
    Json::Object(map) => {
      if map.contains("action") && map.contains("name") {
        let action = match map["action"] {
          Json::String(s) => Some(s)
          _ => None
        }
        let name = match map["name"] {
          Json::String(s) => Some(s)
          _ => None
        }
        return (action, name)
      }
      if map.contains("_positional") {
        match map["_positional"] {
          Json::String(s) => return split_positional(s)
          _ => ()
        }
      }
      (None, None)
    }
    _ => (None, None)
  }
}

///|
/// Split "load coding-fast" into (Some("load"), Some("coding-fast")).
fn split_positional(s : String) -> (String?, String?) {
  let parts : Array[String] = []
  let mut current = ""
  for ch in s {
    if ch == ' ' {
      if current.length() > 0 {
        parts.push(current)
        current = ""
      }
    } else {
      current += ch.to_string()
    }
  }
  if current.length() > 0 {
    parts.push(current)
  }
  match parts.length() {
    0 => (None, None)
    1 => (Some(parts[0]), None)
    _ => (Some(parts[0]), Some(parts[1:].join(" ")))
  }
}

///|
/// Profile names are file stems, never paths. Reject traversal and separator
/// characters before any file operation so callbacks cannot escape the
/// profile directory.
pub fn valid_profile_name(name : String) -> Bool {
  if name.length() == 0 ||
    name == "." ||
    name == ".." ||
    name.contains("/") ||
    name.contains("\\") {
    false
  } else {
    true
  }
}

///|
/// Parse and validate a profile payload. Profiles are provider settings
/// objects; preserving the original JSON text keeps provider extensions
/// responsible for their own fields and defaults. On success the original
/// text is returned unchanged.
pub fn validated_profile_text(
  text : String,
  name : String,
) -> Result[String, String] {
  let json = @json.parse(text) catch {
    _ => return Err("profile " + name + " is not valid JSON")
  }
  match json {
    Json::Object(_) => Ok(text)
    _ => Err("profile " + name + " must contain a JSON object")
  }
}
