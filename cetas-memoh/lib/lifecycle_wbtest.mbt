///|
async test "cancelled task is classified as ACP cancellation" {
  @async.with_task_group(group => {
    let task = group.spawn(() => {
      @async.sleep(10_000)
      ()
    })
    task.cancel()
    let classified : Bool = try {
      task.wait()
      false
    } catch {
      error => prompt_failure_is_cancelled(error)
    }
    assert_true(classified)
  })
}
