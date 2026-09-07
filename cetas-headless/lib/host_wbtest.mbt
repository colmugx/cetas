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
    enable_nmem=Some(false),
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
  // HerdrReporter comes free via build_default_features when herdr is
  // undetectable in tests, and nmem is off — the composition stays silent.
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
async test "build_default_features registers HerdrReporter when HERDR env is set" {
  // Zero-wiring inheritance, positive path: with the herdr gate env set,
  // the composition itself (build_default_features' default detect_herdr)
  // must register a live reporter. Observable through the reporter's spawn:
  // the Idle emit at detect() time runs our fake herdr binary, which touches
  // a sentinel file.
  let scratch = @fs.tmpdir(prefix="cetas-headless-herdr-") catch {
    _ => abort("cetas-headless herdr test: tmpdir failed")
  }
  let sentinel = scratch + "/report-sentinel"
  let fake_bin = scratch + "/fake-herdr"
  @fs.write_file(
    fake_bin,
    "#!/bin/sh\ntouch \"" + sentinel + "\"\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o755,
  ) catch {
    _ => abort("cetas-headless herdr test: fake binary write failed")
  }
  @env.set_env_var("HERDR_ENV", "1")
  @env.set_env_var("HERDR_PANE_ID", "pane-test")
  @env.set_env_var("HERDR_BIN_PATH", fake_bin)
  let (fs, home) = tk_host_fs()
  let (_, warnings) = tk_host(
    fs,
    home~,
    model_override="",
    effort_override="",
    session_id="",
  )
  assert_eq(warnings, [])
  let mut registered = false
  for _ in 0..<40 {
    if @fs.exists(sentinel) {
      registered = true
      break
    }
    @async.sleep(50)
  }
  @env.unset_env_var("HERDR_ENV")
  @env.unset_env_var("HERDR_PANE_ID")
  @env.unset_env_var("HERDR_BIN_PATH")
  assert_true(registered)
}
