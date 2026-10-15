///|
/// session_model_restore.mbt — per-session model restoration on resume.
///
/// Session journals record the model slot (+ explicit effort) behind their
/// last persisted turn (posoco-ext-fs-session's `posoco.model_selection`
/// metadata, fed by the ext-llm `model_selection` bus event). Resuming a
/// session restores that selection over the global `~/.cetas/settings.json`
/// seed, so a conversation continues on the model that produced it. Restore
/// problems degrade to one observer warning and the current selection —
/// never a blocked resume.

///|
/// Core restore decision over injected seams, so the branches are testable
/// without a fully composed agent handle. `warn` reports degraded restores.
/// Returns `true` when the recorded selection was applied (slot switched),
/// `false` for every degraded/skip path.
async fn restore_session_model_selection_over(
  store : @fs_session.JsonlSessionStore,
  manager : ModelManagerFace,
  warn~ : (String) -> Unit,
  session_id : String,
) -> Bool noraise {
  let summary = store.summary(session_id) catch { _ => return false }
  let slot = match summary.model {
    Some(slot) => slot
    None => return false
  }
  // Identical selection: keep the manager untouched — a slot switch drops the
  // provider's quota segments and resets cache state, avoid that churn.
  if slot == manager.manager_active_model_id() &&
    summary.effort == manager.manager_active_effort() {
    return false
  }
  manager.manager_select(model=slot) catch {
    _ => {
      warn(
        "Session '" +
        session_id +
        "' last used model '" +
        slot +
        "', which is not in the manager catalog; keeping the current selection.",
      )
      return false
    }
  }
  match summary.effort {
    Some(effort) =>
      manager.manager_select(effort~) catch {
        _ =>
          warn(
            "Session's reasoning effort '" +
            effort +
            "' is not advertised by model '" +
            slot +
            "'; using the model's default effort.",
          )
      }
    None => ()
  }
  true
}

///|
/// Restore the session's last recorded model selection before a turn or a
/// resumed turn runs. Best-effort end to end: a missing record (legacy
/// journals, stores without the model bus) keeps the global selection; an
/// absent slot or a no-longer-advertised effort warns once and keeps the
/// current selection; an applied restore is written back to the global
/// selection so the next fresh session inherits it.
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
