/// Native autocomplete behavior shared by command completion and future
/// file/model/skill providers.
///
/// Provider policy remains in MoonBit. Ratatui owns only the final List
/// presentation through SelectListModel.

///|
priv enum AutocompleteKeyAction {
  AutocompleteUnhandled
  AutocompleteChanged
  AutocompleteCancelled
  AutocompleteAccepted(String, String)
}

///|
struct AutocompletePopupModel {
  mut active : Bool
  mut prefix : String
  mut list : @ui.SelectListModel
}

///|
fn AutocompletePopupModel::new() -> AutocompletePopupModel {
  { active: false, prefix: "", list: @ui.SelectListModel::new([]), }
}

///|
fn AutocompletePopupModel::is_active(self : AutocompletePopupModel) -> Bool {
  self.active
}

///|
fn AutocompletePopupModel::close(self : AutocompletePopupModel) -> Unit {
  self.active = false
  self.prefix = ""
  self.list = @ui.SelectListModel::new([])
}

///|
fn AutocompletePopupModel::open(
  self : AutocompletePopupModel,
  prefix : String,
  items : Array[@ui.SelectItem],
) -> Bool {
  if items.is_empty() {
    self.close()
    return false
  }
  self.prefix = prefix
  self.list = @ui.SelectListModel::new(items)
  self.active = true
  true
}

///|
fn AutocompletePopupModel::item_count(self : AutocompletePopupModel) -> Int {
  if self.active {
    self.list.item_count()
  } else {
    0
  }
}

///|
fn AutocompletePopupModel::append_scene(
  self : AutocompletePopupModel,
  builder : @ui.SceneBuilder,
  x : UInt,
  y : UInt,
  width : UInt,
  height : UInt,
) -> Unit {
  if self.active {
    self.list.append_scene(builder, x, y, width, height)
  }
}

///|
fn AutocompletePopupModel::handle_key(
  self : AutocompletePopupModel,
  event : @ui.TerminalEvent,
) -> AutocompleteKeyAction {
  if !self.active || !event.is_actionable_key() {
    return AutocompleteUnhandled
  }
  if event.matches_key(@ui.KeyUp, 0U) {
    self.list.previous()
    return AutocompleteChanged
  }
  if event.matches_key(@ui.KeyDown, 0U) {
    self.list.next()
    return AutocompleteChanged
  }
  if event.matches_key(@ui.KeyEscape, 0U) {
    self.close()
    return AutocompleteCancelled
  }
  if event.matches_key(@ui.KeyTab, 0U) || event.matches_key(@ui.KeyEnter, 0U) {
    guard self.list.selected_item() is Some(item) else {
      self.close()
      return AutocompleteCancelled
    }
    let prefix = self.prefix
    let replacement = item.value
    self.close()
    return AutocompleteAccepted(prefix, replacement)
  }
  AutocompleteUnhandled
}

///|
fn native_reserved_local_command(id : String) -> Bool {
  id == "new" ||
  id == "sessions" ||
  id == "rewind" ||
  id == "resume" ||
  id == "compact" ||
  id == "pi" ||
  id == "login" ||
  id == "exit"
}

///|
priv struct FileMentionRank {
  path : String
  score : Int
  is_dir : Bool
}

///|
fn file_mention_score(path : String, query : String) -> Int? {
  let is_dir = path.has_suffix("/")
  let clean = if is_dir { path[:path.length() - 1].to_owned() } else { path }
  let base = match clean.rev_find("/") {
    Some(index) => clean[index + 1:].to_owned().to_lower()
    None => clean.to_lower()
  }
  let full = clean.to_lower()
  let q = query.to_lower()
  let mut depth = 0
  for ch in clean {
    if ch == '/' {
      depth += 1
    }
  }
  let mut score = if q.is_empty() {
    (if is_dir { 120 } else { 100 }) - depth
  } else if base == q {
    100
  } else if base.has_prefix(q) {
    80
  } else if base.contains(q) {
    50
  } else if full.contains(q) {
    30
  } else {
    return None
  }
  if is_dir && !q.is_empty() {
    score += 10
  }
  Some(score)
}

///|
fn rank_file_mention_items(
  entries : Array[String],
  query : String,
  max_items? : Int = 50,
) -> Array[String] {
  let ranked : Array[FileMentionRank] = []
  for path in entries {
    guard file_mention_score(path, query) is Some(score) else { continue }
    let candidate : FileMentionRank = {
      path,
      score,
      is_dir: path.has_suffix("/"),
    }
    let mut at = ranked.length()
    for index, existing in ranked {
      if candidate.score > existing.score ||
        (
          candidate.score == existing.score &&
          candidate.is_dir &&
          !existing.is_dir
        ) {
        at = index
        break
      }
    }
    ranked.insert(at, candidate)
  }
  let out : Array[String] = []
  for candidate in ranked {
    if out.length() >= max_items {
      break
    }
    out.push(candidate.path)
  }
  out
}

///|
fn skill_items_from_outcome(
  outcome : @posoco.CommandOutcome,
) -> Array[@ui.SelectItem] {
  let items : Array[@ui.SelectItem] = []
  guard outcome is @posoco.CommandOutcome::Success(structured~, ..) else {
    return items
  }
  guard structured is Some(Json::Object(root)) else { return items }
  guard root.get("kind") == Some(Json::string("skills_catalog")) else {
    return items
  }
  guard root.get("skills") is Some(Json::Array(entries)) else { return items }
  for entry in entries {
    guard entry is Json::Object(fields) else { continue }
    guard fields.get("name") is Some(Json::String(name)) else { continue }
    let description = match fields.get("description") {
      Some(Json::String(value)) => value
      _ => ""
    }
    let scope = match fields.get("scope") {
      Some(Json::String(value)) => value
      _ => "skill"
    }
    items.push({
      value: "$" + name,
      label: "$" + name,
      description: "[" + scope + "] " + description,
    })
  }
  items
}

///|
async fn NativeHost::refresh_skill_completion_cache(
  self : NativeHost,
) -> Unit noraise {
  for port in self.agent.commands() {
    for def in port.commands() {
      if def.id == "skills" {
        let outcome = port.invoke("skills", Json::object(Map::from_array([]))) catch {
          _ => return
        }
        self.skill_completion_items = skill_items_from_outcome(outcome)
        return
      }
    }
  }
}

///|
fn NativeHost::sync_model_state(
  self : NativeHost,
  outcome : @posoco.CommandOutcome,
) -> Unit {
  guard outcome is @posoco.CommandOutcome::Success(structured~, ..) else {
    return
  }
  guard structured is Some(Json::Array(entries)) else { return }
  for entry in entries {
    guard entry is Json::Object(fields) else { continue }
    if fields.get("active") != Some(Json::boolean(true)) {
      continue
    }
    match fields.get("id") {
      Some(Json::String(id)) => self.active_model = id
      _ => ()
    }
    self.active_effort = match fields.get("active_effort") {
      Some(Json::String(value)) => Some(value)
      _ => None
    }
    return
  }
}

///|
fn NativeHost::command_definitions(
  self : NativeHost,
) -> Array[@posoco.CommandDef] {
  let defs : Array[@posoco.CommandDef] = []
  for port in self.agent.commands() {
    for def in port.commands() {
      defs.push(def)
    }
  }
  defs
}

///|
fn command_query_parts(query : String) -> (String, String) {
  let mut cut = query.length()
  let mut index = 0
  for ch in query {
    if ch is (' ' | '\t' | '\n' | '\r') {
      cut = index
      break
    }
    index += 1
  }
  if cut >= query.length() {
    (query, "")
  } else {
    (query[:cut].to_owned(), query[cut + 1:].to_owned())
  }
}

///|
fn command_detail(def : @posoco.CommandDef) -> String {
  if def.description.is_empty() {
    def.label
  } else {
    def.description
  }
}

///|
fn native_local_command_items(prefix : String) -> Array[@ui.SelectItem] {
  let entries : Array[(String, String)] = [
    ("new", "Start a new session"),
    ("sessions", "Browse project sessions"),
    ("resume", "Resume a session by id"),
    ("rewind", "Rewind the current session"),
    ("compact", "Compact the current session context"),
    ("exit", "Quit Cetas"),
  ]
  let items : Array[@ui.SelectItem] = []
  for entry in entries {
    if entry.0.has_prefix(prefix) {
      items.push({
        value: "/" + entry.0,
        label: "/" + entry.0,
        description: entry.1,
      })
    }
  }
  items
}

///|
fn NativeHost::command_autocomplete(
  self : NativeHost,
  text_before_cursor : String,
) -> (String, Array[@ui.SelectItem])? {
  let matches = @ui.active_autocomplete_matches(text_before_cursor, [
    { trigger: "/", span_spaces: true, },
    { trigger: "$", span_spaces: false, },
    { trigger: "@", span_spaces: false, },
  ])
  guard matches.length() == 1 else { return None }
  let match_ = matches[0]

  if match_.source_index == 1 {
    let items : Array[@ui.SelectItem] = []
    for item in self.skill_completion_items {
      if item.value[1:].to_owned().has_prefix(match_.query) {
        items.push(item)
      }
    }
    return if items.is_empty() {
      None
    } else {
      Some((match_.replacement_prefix, items))
    }
  }

  if match_.source_index == 2 {
    let items : Array[@ui.SelectItem] = []
    for path in rank_file_mention_items(self.workspace_files, match_.query) {
      let is_dir = path.has_suffix("/")
      items.push({
        value: if is_dir {
          "@" + path
        } else {
          "@" + path + " "
        },
        label: path,
        description: if is_dir {
          "directory"
        } else {
          ""
        },
      })
    }
    return if items.is_empty() {
      None
    } else {
      Some((match_.replacement_prefix, items))
    }
  }

  let (command_prefix, arg_prefix) = command_query_parts(match_.query)

  if !arg_prefix.is_empty() || match_.query.contains(" ") {
    for def in self.command_definitions() {
      if def.id == command_prefix && !native_reserved_local_command(def.id) {
        for param in def.params {
          match param.choices {
            Some(choices) => {
              let items : Array[@ui.SelectItem] = []
              for choice in choices {
                if choice.has_prefix(arg_prefix) {
                  items.push({
                    value: "/" + def.id + " " + choice,
                    label: choice,
                    description: def.id +
                    " " +
                    param.name +
                    " — " +
                    param.description,
                  })
                }
              }
              return if items.is_empty() {
                None
              } else {
                Some((match_.replacement_prefix, items))
              }
            }
            None => ()
          }
        }
        return None
      }
    }
    return None
  }

  let items = native_local_command_items(command_prefix)
  for def in self.command_definitions() {
    if def.visible &&
      !native_reserved_local_command(def.id) &&
      def.id.has_prefix(command_prefix) {
      items.push({
        value: "/" + def.id,
        label: "/" + def.id,
        description: command_detail(def),
      })
    }
  }
  if items.is_empty() {
    None
  } else {
    Some((match_.replacement_prefix, items))
  }
}

///|
fn strict_integer_literal(value : String) -> Bool {
  if value.is_empty() {
    return false
  }
  let mut index = 0
  for ch in value {
    if index == 0 && ch == '-' {
      if value.length() == 1 {
        return false
      }
    } else if ch < '0' || ch > '9' {
      return false
    }
    index += 1
  }
  true
}

///|
fn command_args_for(def : @posoco.CommandDef, raw_args : String) -> Json {
  let trimmed = raw_args.trim().to_owned()
  if trimmed.is_empty() {
    return Json::object(Map::from_array([]))
  }
  if def.id == "model" {
    let (slot, effort) = command_query_parts(trimmed)
    let fields : Array[(String, Json)] = [("slot", Json::string(slot))]
    if !effort.trim().is_empty() {
      fields.push(("effort", Json::string(effort.trim().to_owned())))
    }
    return Json::object(Map::from_array(fields))
  }
  if strict_integer_literal(trimmed) {
    let parsed : Json = @json.parse(trimmed) catch {
      _ => Json::string(trimmed)
    }
    return Json::object(Map::from_array([("index", parsed)]))
  }

  let positional = def.params.filter(param => param.positional)
  if positional.length() == 1 && !positional[0].name.is_empty() {
    return Json::object(
      Map::from_array([(positional[0].name, Json::string(trimmed))]),
    )
  }
  Json::object(Map::from_array([("_positional", Json::string(trimmed))]))
}

///|
fn slash_input_parts(input : String) -> (String, String)? {
  let trimmed = input.trim().to_owned()
  if !trimmed.has_prefix("/") || trimmed.length() < 2 {
    return None
  }
  let body = trimmed[1:].to_owned()
  let (id, args) = command_query_parts(body)
  if id.is_empty() {
    None
  } else {
    Some((id, args.trim().to_owned()))
  }
}

///|
fn xml_escape_attribute(value : String) -> String {
  let out = StringBuilder()
  for ch in value {
    match ch {
      '&' => out.write_string("&amp;")
      '<' => out.write_string("&lt;")
      '>' => out.write_string("&gt;")
      '"' => out.write_string("&quot;")
      '\'' => out.write_string("&apos;")
      _ => out.write_char(ch)
    }
  }
  out.to_string()
}

///|
fn parse_skill_mention(input : String) -> (String, String)? {
  let trimmed = input.trim().to_owned()
  if !trimmed.has_prefix("$") || trimmed.length() < 2 {
    return None
  }
  let body = trimmed[1:].to_owned()
  let (name, tail) = command_query_parts(body)
  if name.is_empty() {
    None
  } else {
    Some((name, tail.trim().to_owned()))
  }
}

///|
async fn NativeHost::invoke_skill_mention(
  self : NativeHost,
  name : String,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  for port in self.agent.commands() {
    for def in port.commands() {
      if def.id == "skills" {
        return port.invoke(
          "skills",
          Json::object(
            Map::from_array([
              ("action", Json::string("activate")),
              ("name", Json::string(name)),
            ]),
          ),
        )
      }
    }
  }
  @posoco.CommandOutcome::Failure(reason="skills command is unavailable")
}

///|
fn skill_activation_prompt(
  input : String,
  outcome : @posoco.CommandOutcome,
) -> Result[String, String] {
  guard parse_skill_mention(input) is Some((name, tail)) else {
    return Err("$ needs a skill name")
  }
  match outcome {
    @posoco.CommandOutcome::Failure(reason~) => Err(reason)
    @posoco.CommandOutcome::NeedsInput(prompt~) => Err(prompt)
    @posoco.CommandOutcome::Success(structured~, ..) => {
      guard structured is Some(Json::Object(fields)) else {
        return Err("skills activation returned no structured payload")
      }
      guard fields.get("kind") == Some(Json::string("agent_skill_activation")) else {
        return Err("skills activation returned an unexpected payload")
      }
      guard fields.get("instructions") is Some(Json::String(instructions)) else {
        return Err("skills activation returned no instructions")
      }
      let task = if tail.is_empty() {
        "Follow the activated skill's instructions."
      } else {
        tail
      }
      Ok(
        "<activated-skill name=\"" +
        xml_escape_attribute(name) +
        "\">\n" +
        instructions +
        "\n</activated-skill>\n\n" +
        task,
      )
    }
  }
}

///|
async fn NativeHost::invoke_slash_command(
  self : NativeHost,
  input : String,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  guard slash_input_parts(input) is Some((id, raw_args)) else {
    return @posoco.CommandOutcome::Failure(reason="invalid slash command")
  }

  if id == "sessions" {
    return self.session_catalog()
  }
  if id == "resume" {
    let target = raw_args.trim().to_owned()
    if target.is_empty() {
      return @posoco.CommandOutcome::Failure(
        reason="/resume requires a session id",
      )
    }
    match self.switch_session(target) {
      Ok(_) =>
        return @posoco.CommandOutcome::Success(
          feedback="resumed session: " + target,
          structured=None,
          ui_hint=None,
        )
      Err(reason) =>
        return @posoco.CommandOutcome::Failure(
          reason="invalid session id: " + reason,
        )
    }
  }
  if id == "new" {
    let target = @cetas_core.mint_session_id()
    match self.switch_session(target) {
      Ok(_) =>
        return @posoco.CommandOutcome::Success(
          feedback="new session: " + target,
          structured=None,
          ui_hint=None,
        )
      Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
    }
  }

  if id == "compact" {
    if !raw_args.trim().is_empty() {
      return @posoco.CommandOutcome::Failure(
        reason="/compact takes no arguments",
      )
    }
    let attempted = Ok(
      @cetas_core.run_compact(self.agent, self.session.session_id()),
    ) catch {
      error => Err(error)
    }
    match attempted {
      Ok(outcome) => {
        ignore(self.session.switch_to(outcome.final_session_id))
        return @posoco.CommandOutcome::Success(
          feedback="context compacted (" +
            outcome.mode +
            ", " +
            outcome.messages_after.to_string() +
            " messages)",
          structured=None,
          ui_hint=None,
        )
      }
      Err(error) =>
        return @posoco.CommandOutcome::Failure(reason=error.to_string())
    }
  }

  if native_reserved_local_command(id) {
    return @posoco.CommandOutcome::Failure(
      reason="native /" + id + " workflow is not implemented yet",
    )
  }

  for port in self.agent.commands() {
    for def in port.commands() {
      if def.id == id {
        let outcome = port.invoke(id, command_args_for(def, raw_args))
        if id == "skills" && raw_args.trim().is_empty() {
          self.skill_completion_items = skill_items_from_outcome(outcome)
        }
        if id == "model" || id == "effort" {
          self.sync_model_state(outcome)
        }
        return outcome
      }
    }
  }
  @posoco.CommandOutcome::Failure(reason="command not found: " + id)
}

///|
fn autocomplete_validation_marker() -> Int {
  let popup = AutocompletePopupModel::new()
  if popup.is_active() || popup.open("/", []) || popup.is_active() {
    return 0
  }

  if !popup.open("/h", [
      { value: "/help", label: "/help", description: "Help", },
      { value: "/handoff", label: "/handoff", description: "Handoff", },
    ]) ||
    popup.item_count() != 2 {
    return 0
  }

  match popup.handle_key(validation_key(10U, 0U, 0U, 1U)) {
    AutocompleteChanged => ()
    _ => return 0
  }
  match popup.handle_key(validation_key(2U, 0U, 0U, 1U)) {
    AutocompleteAccepted(prefix, replacement) if prefix == "/h" &&
      replacement == "/handoff" => ()
    _ => return 0
  }
  if popup.is_active() {
    return 0
  }

  guard parse_skill_mention("$cetas-usage explain config")
    is Some((skill, tail)) else {
    return 0
  }
  if skill != "cetas-usage" || tail != "explain config" {
    return 0
  }

  let activated = skill_activation_prompt(
    "$demo do work",
    @posoco.CommandOutcome::Success(
      feedback="activated",
      structured=Some(
        Json::object(
          Map::from_array([
            ("kind", Json::string("agent_skill_activation")),
            ("name", Json::string("demo")),
            ("instructions", Json::string("STEP")),
          ]),
        ),
      ),
      ui_hint=None,
    ),
  )
  match activated {
    Ok(prompt) =>
      if !prompt.contains("<activated-skill name=\"demo\">") ||
        !prompt.contains("STEP") ||
        !prompt.has_suffix("do work") {
        return 0
      }
    Err(_) => return 0
  }

  let ranked = rank_file_mention_items(
    ["src/", "src/main.mbt", "README.md", "docs/main.md"],
    "main",
  )
  if ranked.length() != 2 ||
    ranked[0] != "src/main.mbt" ||
    ranked[1] != "docs/main.md" {
    return 0
  }

  if !strict_integer_literal("12") ||
    !strict_integer_literal("-2") ||
    strict_integer_literal("1e3") ||
    strict_integer_literal("0x10") {
    return 0
  }
  1
}
