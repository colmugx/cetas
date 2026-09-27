///|
/// ACP model/effort options for one Memoh session.
///
/// These options are authoritative runtime state only. Unlike generic Cetas,
/// cetas-memoh never persists the selected slot or effort as a future default.

///|
fn memoh_select_option(
  value : String,
  name : String,
) -> @acp.SessionConfigSelectOption {
  { value, name, description: Omitted, meta: Omitted, }
}

///|
fn memoh_slot_name(slot : @llm.ModelSlot) -> String {
  if slot.label.is_empty() {
    slot.id
  } else {
    slot.label
  }
}

///|
fn memoh_effort_value(
  router : @llm.RouterModelPort,
  slot : @llm.ModelSlot,
) -> String {
  match router.active_effort() {
    Some(value) => value
    None =>
      match slot.default_effort {
        Some(value) => value
        None => slot.thinking_efforts[0]
      }
  }
}

///|
fn memoh_config_options(
  router : @llm.RouterModelPort,
) -> Array[@acp.SessionConfigOption] {
  let model_options : Array[@acp.SessionConfigSelectOption] = []
  for slot in router.list_slots() {
    model_options.push(memoh_select_option(slot.id, memoh_slot_name(slot)))
  }
  let result : Array[@acp.SessionConfigOption] = [
    {
      id: "model",
      name: "Model",
      description: Omitted,
      category: Value(@acp.SessionConfigOptionCategory::Model),
      kind: @acp.SessionConfigOptionKind::Select({
        current_value: router.active_slot_id(),
        options: @acp.SessionConfigSelectOptions::Ungrouped(model_options),
      }),
      meta: Omitted,
    },
  ]

  let active_id = router.active_slot_id()
  for slot in router.list_slots() {
    if slot.id == active_id && !slot.thinking_efforts.is_empty() {
      let efforts : Array[@acp.SessionConfigSelectOption] = []
      for effort in slot.thinking_efforts {
        efforts.push(memoh_select_option(effort, effort))
      }
      result.push({
        id: "effort",
        name: "Effort",
        description: Omitted,
        category: Value(@acp.SessionConfigOptionCategory::ThoughtLevel),
        kind: @acp.SessionConfigOptionKind::Select({
          current_value: memoh_effort_value(router, slot),
          options: @acp.SessionConfigSelectOptions::Ungrouped(efforts),
        }),
        meta: Omitted,
      })
    }
  }
  result
}

///|
/// Apply one Memoh-owned runtime selection.
///
/// The selected model/effort is intentionally not persisted. Memoh owns the
/// session preference and will re-apply it when it creates a fresh runtime.
fn apply_memoh_config_option(
  router : @llm.RouterModelPort,
  bridge : @ext_acp.AcpBridge,
  config_id : String,
  value : @acp.SessionConfigValue,
) -> Result[Array[@acp.SessionConfigOption], String] {
  let value_id = match value {
    @acp.SessionConfigValue::ValueId(id) => id
    @acp.SessionConfigValue::Boolean(_) =>
      return Err("config option '" + config_id + "' expects a value id")
  }

  match config_id {
    "model" => {
      if !router.list_slot_ids().contains(value_id) {
        return Err("unknown model slot: " + value_id)
      }
      router.switch_slot(value_id) catch {
        _ => return Err("failed to switch model slot: " + value_id)
      }
    }
    "effort" =>
      router.select_effort(router.active_slot_id(), value_id) catch {
        @posoco.CommandError::InvalidArgs(reason~) => return Err(reason)
        @posoco.CommandError::ExecutionFailed(reason) => return Err(reason)
        @posoco.CommandError::NotFound(reason) => return Err(reason)
      }
    _ => return Err("unknown config option: " + config_id)
  }

  bridge.set_context_window(router_context_window(router))
  Ok(memoh_config_options(router))
}
