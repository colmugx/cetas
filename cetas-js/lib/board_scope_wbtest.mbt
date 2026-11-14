///|
/// Run one board test body inside the two host task groups production hands
/// to the workflow surface: the core-async lifetime group every board
/// coordinator/fuwaroid worker spawns on, and the `moonbitlang/core/async` I/O
/// group child agent work runs on.
async fn board_scope(
  body : async (@async.TaskGroup, @async.TaskGroup) -> Unit,
) -> Unit {
  @async.with_task_group(async fn(lifetime) {
    @async.with_task_group(async fn(group) { body(lifetime, group) })
  })
}
