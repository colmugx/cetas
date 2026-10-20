///|
/// Add presentation details from the very same detached authoritative view.
/// Never reload after a mutation just to manufacture a successful response.
fn workflow_observation(view : @board.BoardWorkflowView) -> Json {
  guard view.to_json() is Object(root) else { return view.to_json() }
  let root = root.copy()
  if root.get("board") is Some(Object(board)) {
    let board = board.copy()
    let scope = view.run.map(r => r.scope).unwrap_or([])
    board["tasks"] = Json::array(
      view.snapshot.tasks.map(t => {
        (
          {
            "id": t.id.value,
            "title": t.title,
            "description": t.description,
            "priority": "\{Repr(t.priority)}",
            "definition_of_done": Json::array(
              t.definition_of_done.map(Json::string),
            ),
            "stage": "\{Repr(t.stage)}",
            "dependencies": Json::array(
              t.dependencies.map(d => Json::string(d.value)),
            ),
            "execution_authorized": Json::boolean(scope.contains(t.id.value)),
          } : Json)
      }),
    )
    board["attempts"] = Json::array(
      view.snapshot.attempts.map(a => {
        (
          {
            "id": a.id.value,
            "task_id": a.task_id.value,
            "kind": "\{Repr(a.kind)}",
            "status": "\{Repr(a.status)}",
            "review": "\{Repr(a.review)}",
          } : Json)
      }),
    )
    root["board"] = Json::object(board)
  }
  if root.get("workflow") is Some(Object(fields)) && view.run is Some(run) {
    let fields = fields.copy()
    fields["active_count"] = Json::number(run.runner.active_count.to_double())
    fields["admitted_executions"] = Json::number(
      run.runner.admitted.to_double(),
    )
    fields["succeeded_executions"] = Json::number(
      run.runner.succeeded.to_double(),
    )
    fields["failed_executions"] = Json::number(run.runner.failed.to_double())
    fields["cancelled_executions"] = Json::number(
      run.runner.cancelled.to_double(),
    )
    fields["planning_active"] = Json::boolean(run.planning_active)
    root["workflow"] = Json::object(fields)
  }
  Json::object(root)
}
