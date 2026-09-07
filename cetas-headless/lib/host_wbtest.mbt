///|
/// host_wbtest.mbt — the headless host over the shared cetas-core seam:
/// composition, run-scoped model/effort overrides (never persisted), and
/// the --session resume id.

///|
/// A FakeFs settings root (under a real temp home — the fs-session store
/// rides the native filesystem) with two advertised opencode slots and a
/// persisted selection, so override behavior has something to merge over.
async fn tk_host_fs() -> (FakeFs, String) {
  let fs = FakeFs()
  let home = @fs.tmpdir(prefix="cetas-headless-test-")
  fs.files[home + "/.cetas/settings.json"] = "{\"providers\":{\"opencode\":{\"api_key\":\"sk-zen-test\"}},\"model\":\"opencode/claude-sonnet-5\"}"
  fs.files[home + "/.cetas/model_lists.json"] = "{\"opencode\":[{\"model_id\":\"claude-sonnet-5\",\"thinking_efforts\":[\"low\",\"high\"],\"default_effort\":null,\"context_window\":null},{\"model_id\":\"gpt-5.1-codex\",\"thinking_efforts\":[\"low\",\"medium\",\"high\"],\"default_effort\":null,\"context_window\":null}]}"
  (fs, home)
}

///|
/// Compose a host over `fs` with the given overrides; capture every warn.
async fn tk_host(
  fs : FakeFs,
  home~ : String,
  model_override~ : String,
  effort_override~ : String,
  session_id~ : String,
  goal? : String = "",
) -> (CetasHeadlessHost, Array[String]) {
  let warnings : Array[String] = []
  let host = CetasHeadlessHost::CetasHeadlessHost(
    home~,
    cwd="/w",
    mode=@permission.Yolo,
    approval=None,
    ui=None,
    model_override~,
    effort_override~,
    session_id~,
    goal~,
    fs=Some(fs as &@workspace.WorkspaceFs),
    warn=fn(text : String) { warnings.push(text) },
  )
  (host, warnings)
}

///|
async test "host composes over the core seam with the persisted selection and a fresh id" {
  let (fs, home) = tk_host_fs()
  let (host, warnings) = tk_host(
    fs,
    home~,
    model_override="",
    effort_override="",
    session_id="",
  )
  assert_eq(host.router.active_slot_id(), "opencode/claude-sonnet-5")
  assert_true(host.session_id.has_prefix("cetas-"))
  // nmem rides the compiled personal flavor; nothing warns — the
  // composition stays silent.
  assert_eq(warnings, [])
}

///|
async test "host applies --model/--effort as a run-scoped merge and never persists them" {
  let (fs, home) = tk_host_fs()
  let (host, warnings) = tk_host(
    fs,
    home~,
    model_override="opencode/gpt-5.1-codex",
    effort_override="high",
    session_id="",
  )
  assert_eq(host.router.active_slot_id(), "opencode/gpt-5.1-codex")
  assert_eq(host.router.active_effort(), Some("high"))
  assert_eq(warnings, [])
  // The persisted settings file is byte-identical: overrides are
  // run-scoped and never written back.
  assert_eq(
    fs.files[home + "/.cetas/settings.json"],
    "{\"providers\":{\"opencode\":{\"api_key\":\"sk-zen-test\"}},\"model\":\"opencode/claude-sonnet-5\"}",
  )
}

///|
async test "host effort-only override lands on the active slot; unknown model and effort degrade with a warning" {
  let (fs, home) = tk_host_fs()
  let (effort_host, _) = tk_host(
    fs,
    home~,
    model_override="",
    effort_override="high",
    session_id="",
  )
  assert_eq(effort_host.router.active_slot_id(), "opencode/claude-sonnet-5")
  assert_eq(effort_host.router.active_effort(), Some("high"))
  let (fs2, home2) = tk_host_fs()
  let (bad_model, warnings) = tk_host(
    fs2,
    home=home2,
    model_override="ghost/model",
    effort_override="bogus",
    session_id="",
  )
  // The unknown slot keeps the persisted selection; the bogus effort keeps
  // the slot default; both degrade observably.
  assert_eq(bad_model.router.active_slot_id(), "opencode/claude-sonnet-5")
  assert_true(bad_model.router.active_effort() is None)
  let mut unknown_model = false
  let mut unsupported_effort = false
  for message in warnings {
    if message.contains("--model 'ghost/model' is not a configured model slot") {
      unknown_model = true
    }
    if message.contains("--effort 'bogus' rejected by model slot") {
      unsupported_effort = true
    }
  }
  assert_true(unknown_model)
  assert_true(unsupported_effort)
}

///|
async test "host resumes an explicit --session id verbatim" {
  let (fs, home) = tk_host_fs()
  let (host, _) = tk_host(
    fs,
    home~,
    model_override="",
    effort_override="",
    session_id="cetas-resume-me",
  )
  assert_eq(host.session_id, "cetas-resume-me")
}

///|
async test "--goal arms the goal runner and goal_update_plan is routable" {
  let (fs, home) = tk_host_fs()
  let (host, warnings) = tk_host(
    fs,
    home~,
    model_override="",
    effort_override="",
    session_id="",
    goal="make the build green",
  )
  assert_true(host.routing.contains("goal_update_plan"))
  // Composition stays silent with the runner armed.
  assert_eq(warnings, [])
}

///|
async test "plan mode joins via bus_exts and its enter/exit tools are routable" {
  let (fs, home) = tk_host_fs()
  let (host, _) = tk_host(
    fs,
    home~,
    model_override="",
    effort_override="",
    session_id="",
  )
  assert_true(host.routing.contains("enter_plan_mode"))
  assert_true(host.routing.contains("exit_plan_mode"))
}

///|
async test "terminal plan review without a tty dismisses; EOF dismisses too" {
  let notes : Array[String] = []
  let review = TerminalPlanReview::TerminalPlanReview(tty=None, notice=fn(
    text : String,
  ) {
    notes.push(text)
  })
  let decision = @plan.PlanReviewSource::review(review, @plan.PlanReviewRequest::{
    plan: "refactor the loop",
  })
  // Dismiss is the only no-terminal decision that ends planning without
  // granting edits — Revise would loop the model with no one to answer.
  assert_true(decision is @plan.PlanReviewDecision::Dismiss)
  assert_true(notes[0].contains("no terminal"))
  // EOF on a live tty is the same degradation.
  let eof_review = TerminalPlanReview::TerminalPlanReview(
    tty=Some(FakeTty::FakeTty([]).channel()),
  )
  assert_true(
    @plan.PlanReviewSource::review(eof_review, @plan.PlanReviewRequest::{
      plan: "refactor the loop",
    })
    is @plan.PlanReviewDecision::Dismiss,
  )
}

///|
async test "without mcp.json the host composes with an MCP-free routing table" {
  let (fs, home) = tk_host_fs()
  let (host, warnings) = tk_host(
    fs,
    home~,
    model_override="",
    effort_override="",
    session_id="",
  )
  // Discovery degrades to an empty bridge: composition succeeds, no MCP
  // tool reaches the routing table, nothing warns.
  for name in host.routing.keys() {
    assert_false(name.has_prefix("mcp__"))
  }
  assert_false(host.routing.contains("goal_update_plan"))
  assert_eq(warnings, [])
}
