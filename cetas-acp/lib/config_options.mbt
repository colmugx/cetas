///|
/// config_options.mbt — the ACP config-option surface of the cetas host.
///
/// `session/new` advertises a `model` selector over the router's slots and —
/// when the active slot advertises reasoning efforts — an `effort` selector
/// over them (ACP's ThoughtLevel category; cetas vocabulary is "effort").
/// `session/set_config_option` routes both ids through the router and
/// persists the outcome to `~/.cetas/settings.json` via cetas-core, so the
/// selection outlives the process. Selection is process-global (see the
/// host header): any session's switch retunes every session, v1 accepts
/// last-selection-wins.

///|
/// Serializes every stderr write in this host: the async runtime's shared
/// stderr handle panics on overlapping writes (`guard! write is Idle`), so
/// concurrent failing turns or tests would abort the process without this.
let acp_stderr_mutex : @async.Mutex = @async.Mutex::Mutex()

///|
/// Best-effort stderr diagnostic: warnings must never fail a selection
/// switch or composition, and stderr writes raise a generic error that
/// specific-error functions cannot propagate.
async fn acp_warn(message : String) -> Unit noraise {
  acp_stderr_mutex.acquire() catch {
    // Cancelled while queued: skip the diagnostic rather than write
    // unserialized or release a lock we never acquired.
    _ => return
  }
  defer acp_stderr_mutex.release()
  @stdio.stderr.write(message) catch {
    _ => ()
  }
}

///|
/// One ACP select option from a value/name pair.
fn tk_select_option(
  value : String,
  name : String,
) -> @acp.SessionConfigSelectOption {
  { value, name, description: Omitted, meta: Omitted }
}

///|
/// The non-empty display name for a slot: its label, or the id when the
/// label is blank.
fn slot_display_name(slot : @llm.ModelSlot) -> String {
  if slot.label.length() == 0 {
    slot.id
  } else {
    slot.label
  }
}

///|
/// The effort the `effort` selector should show as current: the explicit
/// selection, else the slot's advertised default, else the first option.
fn current_effort_value(
  explicit : String?,
  default_effort : String?,
  efforts : Array[String],
) -> String {
  match explicit {
    Some(effort) => effort
    None =>
      match default_effort {
        Some(effort) => effort
        None => efforts[0]
      }
  }
}

///|
/// Build the configOptions for the router's current state: always a `model`
/// arm, plus an `effort` arm when the active slot advertises efforts.
fn build_config_options(
  router : @llm.RouterModelPort,
) -> Array[@acp.SessionConfigOption] {
  let options : Array[@acp.SessionConfigSelectOption] = []
  for slot in router.list_slots() {
    options.push(tk_select_option(slot.id, slot_display_name(slot)))
  }
  let model : @acp.SessionConfigOption = {
    id: "model",
    name: "Model",
    description: Omitted,
    category: Value(@acp.SessionConfigOptionCategory::Model),
    kind: @acp.SessionConfigOptionKind::Select({
      current_value: router.active_slot_id(),
      options: @acp.SessionConfigSelectOptions::Ungrouped(options),
    }),
    meta: Omitted,
  }
  let config_options : Array[@acp.SessionConfigOption] = [model]
  let active_id = router.active_slot_id()
  for slot in router.list_slots() {
    if slot.id == active_id && !slot.thinking_efforts.is_empty() {
      let effort_options : Array[@acp.SessionConfigSelectOption] = []
      for effort in slot.thinking_efforts {
        effort_options.push(tk_select_option(effort, effort))
      }
      let effort_option : @acp.SessionConfigOption = {
        id: "effort",
        name: "Effort",
        description: Omitted,
        category: Value(@acp.SessionConfigOptionCategory::ThoughtLevel),
        kind: @acp.SessionConfigOptionKind::Select({
          current_value: current_effort_value(
            router.active_effort(),
            slot.default_effort,
            slot.thinking_efforts,
          ),
          options: @acp.SessionConfigSelectOptions::Ungrouped(effort_options),
        }),
        meta: Omitted,
      }
      config_options.push(effort_option)
    }
  }
  config_options
}

///|
/// Apply one `session/set_config_option` to the router and persist the new
/// selection. Returns the refreshed configOptions on success, or a plain
/// message (surfaced as a handler error) when the id or value is invalid.
/// A persistence failure is NOT an error: the in-memory switch already
/// committed, so it only warns on stderr and never overturns the selection.
async fn apply_config_option(
  router : @llm.RouterModelPort,
  fs : &@workspace.WorkspaceFs,
  home : String,
  config_id : String,
  value : @acp.SessionConfigValue,
) -> Result[Array[@acp.SessionConfigOption], String] noraise {
  let value_id = match value {
    @acp.SessionConfigValue::ValueId(id) => id
    @acp.SessionConfigValue::Boolean(_) =>
      return Err("config option '" + config_id + "' expects a value id")
  }
  let outcome : Result[Unit, String] = match config_id {
    "model" =>
      if !router.list_slot_ids().contains(value_id) {
        Err("unknown model slot: " + value_id)
      } else {
        try {
          router.switch_slot(value_id)
          Ok(())
        } catch {
          _ => Err("failed to switch model slot: " + value_id)
        }
      }
    "effort" =>
      try {
        router.select_effort(router.active_slot_id(), value_id)
        Ok(())
      } catch {
        @posoco.CommandError::InvalidArgs(reason~) => Err(reason)
        @posoco.CommandError::ExecutionFailed(reason) => Err(reason)
        @posoco.CommandError::NotFound(reason) => Err(reason)
      }
    _ => Err("unknown config option: " + config_id)
  }
  match outcome {
    Err(message) => Err(message)
    Ok(_) => {
      @cetas_core.write_active_model_selection(
        fs,
        home~,
        @cetas_core.ActiveModelSelection::from_current(
          router.active_slot_id(),
          router.active_effort(),
        ),
      ) catch {
        _ =>
          acp_warn(
            "cetas-acp: failed to persist the model selection to " +
            home +
            "/.cetas/settings.json; the change is active for this process only\n",
          )
      }
      Ok(build_config_options(router))
    }
  }
}

///|
/// `session/set_config_option`: switch the process-global model/effort,
/// persist it, answer with the refreshed configOptions, and best-effort push
/// a `config_option_update` so any other surface tracking the options sees
/// the change (the kimi emitConfigOptionUpdate posture). Invalid ids/values
/// reject the request with a typed application error carrying the reason,
/// so editors show the user's mistake instead of an internal error; a
/// persistence failure does not.
pub async fn CetasAcpHost::handle_set_config_option(
  self : CetasAcpHost,
  context : @acp.AgentContext,
  params : @acp.SetSessionConfigOptionParams,
) -> @acp.SetSessionConfigOptionResult raise @acp.HandlerError {
  match
    apply_config_option(
      self.router,
      self.fs,
      self.home,
      params.config_id,
      params.value,
    ) {
    Ok(config_options) => {
      context.session_update({
        session_id: params.session_id,
        update: @acp.SessionUpdate::ConfigOptionUpdate({
          config_options,
          meta: Omitted,
        }),
        meta: Omitted,
      }) catch {
        _ =>
          acp_warn(
            "cetas-acp: config_option_update push failed (session=\{params.session_id})\n",
          )
      }
      { config_options, meta: Omitted }
    }
    Err(message) =>
      raise @acp.HandlerError::Application(message="cetas-acp: " + message)
  }
}
