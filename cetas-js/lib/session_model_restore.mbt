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
        "The session model '\{model_id}' is unavailable in the active model catalog; keeping the current selection.",
      )
      return false
    }
  }
  match effort {
    Some(value) =>
      manager.manager_select(effort=value) catch {
        _ =>
          warn(
            "The saved reasoning effort '\{value}' is unavailable for this model; using the model's default effort.",
          )
      }
    None => ()
  }
  true
}

///|
/// Machine-readable payload of the `session_model_restored` Custom event:
/// the now-active selection after one restore, in the same vocabulary as
/// the persisted `ActiveModelSelection` (effort `null` = model default).
fn session_model_restored_event(
  manager : ModelManagerFace,
  session_id : String,
) -> Json {
  let effort = match manager.manager_active_effort() {
    Some(value) => Json::string(value)
    None => Json::null()
  }
  Json::object(
    Map::from_array([
      ("session_id", Json::string(session_id)),
      ("model_id", Json::string(manager.manager_active_model_id())),
      ("effort", effort),
    ]),
  )
}

///|
/// Apply the stored model for one session. Call sites: the host's
/// user-intent session switch (`cetas_js_restore_session_model`) and the
/// turn-time fallback. The session is marked attempted up front, so a later
/// turn on the same session never overrides a user's explicit post-resume
/// `/model` choice. Missing or foreign selections do not alter the current
/// manager; a valid selection also updates the default model for subsequent
/// sessions and is announced to the host (status republication plus the
/// `session_model_restored` Custom event).
async fn restore_session_model_selection(
  handle : CetasJsAgent,
  session_id : String,
) -> Bool noraise {
  handle.model_restored_for = Some(session_id)
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
    // Same republication path as a successful /model command: the Magpie
    // manager owns no status publisher of its own.
    handle.manager.manager_publish_status(handle.manager_bus)
    handle.observer.on_event(
      Custom(
        source="cetas-js.bridge",
        label="session_model_restored",
        data=session_model_restored_event(handle.manager, session_id),
      ),
    )
  }
  applied
}

///|
/// Eagerly restore the recorded model selection of one session at the host's
/// user-intent session switch. The applied selection is announced to the host
/// through the `session_model_restored` Custom event (status bar + transcript
/// notice) instead of surfacing only at the first message. Idempotent per
/// session: a repeated call reports `already_restored` and never switches.
pub fn cetas_js_restore_session_model(
  handle : CetasJsAgent,
  session_id : String,
) -> @js_async.Promise[String] {
  @js_async.Promise::from_async() <| () => {
    let already = handle.model_restored_for == Some(session_id)
    let applied = if already {
      false
    } else {
      restore_session_model_selection(handle, session_id)
    }
    Json::object(
      Map::from_array([
        ("applied", Json::boolean(applied)),
        ("already_restored", Json::boolean(already)),
      ]),
    ).stringify()
  }
}
