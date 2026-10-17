///|
/// Restore the model recorded for a session using an owner-qualified
/// selection. Older unqualified slot records are interpreted only by the
/// manager that originally wrote them.
async fn restore_session_model_selection_over(
  store : @fs_session.JsonlSessionStore,
  manager : ModelManagerFace,
  warn~ : (String) -> Unit,
  session_id : String,
) -> Bool noraise {
  let session = store.load(session_id) catch { _ => return false }
  let recorded : (String, String?)? = if session.metadata.contains(
      @fs_session.MODEL_SELECTION_V2_METADATA_KEY,
    ) {
    match
      @fs_session.session_selection_v2_for_owner(
        session.metadata,
        manager.manager_control().manager_id(),
      ) {
      Some(selection) => Some((selection.model_id, selection.effort))
      None => return false
    }
  } else {
    if !manager.manager_accepts_legacy_selection() {
      return false
    }
    @fs_session.model_selection_from_metadata(session.metadata)
  }
  let (model_id, effort) = match recorded {
    Some(value) => value
    None => return false
  }
  if model_id == manager.manager_active_model_id() &&
    effort == manager.manager_active_effort() {
    return false
  }
  manager.manager_select(model=model_id) catch {
    _ => {
      warn(
        "The session model is unavailable in the active model catalog; keeping the current selection.",
      )
      return false
    }
  }
  match effort {
    Some(value) =>
      manager.manager_select(effort=value) catch {
        _ =>
          warn(
            "The saved reasoning effort is unavailable for this model; using the model's default effort.",
          )
      }
    None => ()
  }
  true
}

///|
/// Apply the stored model before a turn or resumed turn. Missing or foreign
/// selections do not alter the current manager; a valid selection also
/// updates the default model for subsequent sessions.
async fn restore_session_model_selection(
  handle : CetasJsAgent,
  session_id : String,
) -> Unit noraise {
  let applied = restore_session_model_selection_over(
    handle.store,
    handle.manager,
    warn=fn(message) {
      handle.observer.on_event(
        Custom(
          source="cetas-js.bridge",
          label="session_model_restore_warning",
          data=Json::object(
            Map::from_array([("message", Json::string(message))]),
          ),
        ),
      )
    },
    session_id,
  )
  if applied {
    persist_active_model_selection(handle)
  }
}
