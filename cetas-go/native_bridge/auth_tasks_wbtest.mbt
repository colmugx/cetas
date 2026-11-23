///|
async test "cancelled login releases the terminal before the replacement runs" {
  @core_async.with_task_group(async fn(group) {
    @core_async.with_timeout(2000, async fn() {
      let tasks = NativeAuthTasks::new()
      let entered = Ref(false)
      let unwinding = Ref(false)
      let release = Ref(false)
      let notices : Array[String] = []
      let first = tasks
        .start_flow(
          group,
          async fn() {
            entered.val = true
            @core_async.protect_from_cancel(async fn() {
              while !release.val {
                @core_async.pause()
              }
            })
            unwinding.val = true
            Json::null()
          },
          (id, _) => notices.push(id),
        )
        .unwrap()
      while !entered.val {
        @core_async.pause()
      }
      assert_true(
        tasks.start_flow(group, () => Json::null(), (_, _) => ()) is None,
      )
      assert_true(tasks.cancel(group, first, () => notices.push("cancelled")))
      assert_false(tasks.cancel(group, first, () => notices.push("duplicate")))
      let retry = tasks
        .start_flow(
          group,
          () => {
            assert_true(unwinding.val)
            Json::null()
          },
          (id, _) => notices.push(id),
        )
        .unwrap()
      assert_false(tasks.cancel(group, first, () => notices.push("stale")))
      @core_async.pause()
      assert_true(notices.is_empty())
      release.val = true
      while notices.length() < 2 {
        @core_async.pause()
      }
      assert_eq(notices, ["cancelled", retry])
      assert_true(
        tasks.start_flow(group, () => Json::null(), (_, _) => ()) is Some(_),
      )
    })
  })
}

///|
async test "cancelling before provider work starts does not wedge the login slot" {
  @core_async.with_task_group(async fn(group) {
    @core_async.with_timeout(2000, async fn() {
      let tasks = NativeAuthTasks::new()
      let ran = Ref(false)
      let cancelled = Ref(false)
      let id = tasks
        .start_flow(
          group,
          async fn() {
            @core_async.pause()
            ran.val = true
            Json::null()
          },
          (_, _) => ran.val = true,
        )
        .unwrap()
      assert_true(tasks.cancel(group, id, () => cancelled.val = true))
      while !cancelled.val {
        @core_async.pause()
      }
      assert_false(ran.val)
      assert_true(
        tasks.start_flow(group, () => Json::null(), (_, _) => ()) is Some(_),
      )
    })
  })
}
