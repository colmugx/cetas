///|
/// host_wbtest.mbt — the headless host over the shared cetas-core seam:
/// composition, run-scoped model/effort overrides (never persisted; a bad
/// override hard-fails naming the valid slots/efforts), the end-to-end
/// routing the override buys, and the --session resume id.

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
/// The raise is annotated so catch sites see the concrete error type.
async fn tk_host(
  fs : FakeFs,
  home~ : String,
  model_override~ : String,
  effort_override~ : String,
  session_id~ : String,
) -> (CetasHeadlessHost, Array[String]) raise @posoco.CompositionError {
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
async test "host effort-only override lands on the active slot" {
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
}

///|
/// Compose with the given overrides, capturing the composition failure as a
/// value. `Err` carries the raised CompositionError; `Ok` means the host
/// composed.
async fn tk_failed_compose(
  fs : FakeFs,
  home~ : String,
  model_override~ : String,
  effort_override~ : String,
) -> Result[CetasHeadlessHost, @posoco.CompositionError] {
  let attempted = Ok(
    tk_host(fs, home~, model_override~, effort_override~, session_id=""),
  ) catch {
    error => Err(error)
  }
  match attempted {
    Ok((host, _warnings)) => Ok(host)
    Err(error) => Err(error)
  }
}

///|
async test "unknown --model fails composition and names the configured slots" {
  let (fs, home) = tk_host_fs()
  let failed = tk_failed_compose(
    fs,
    home~,
    model_override="ghost/model",
    effort_override="",
  )
  match failed {
    Err(@posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~)) => {
      assert_true(manifest_id.has_suffix(".model_override"))
      assert_true(detail.contains("unknown --model 'ghost/model'"))
      // The error must teach the slot vocabulary: both fixture slot ids.
      assert_true(detail.contains("opencode/claude-sonnet-5"))
      assert_true(detail.contains("opencode/gpt-5.1-codex"))
    }
    _ => fail("an unknown --model slot must fail composition")
  }
}

///|
async test "unknown --effort fails composition listing the slot's supported efforts" {
  let (fs, home) = tk_host_fs()
  let failed = tk_failed_compose(
    fs,
    home~,
    model_override="",
    effort_override="bogus",
  )
  match failed {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) => {
      assert_true(
        detail.contains(
          "--effort 'bogus' rejected by model slot 'opencode/claude-sonnet-5'",
        ),
      )
      // The rejecting slot's advertised vocabulary (its curated preset:
      // low/medium/high/xhigh/max) must be listed in full.
      assert_true(
        detail.contains("supported efforts: low, medium, high, xhigh, max"),
      )
    }
    _ => fail("an unsupported --effort must fail composition")
  }
}

///|
async test "apply_model_override raises when the resolved slot is missing from the router" {
  // The catalogs name a slot the router does not carry: the switch itself
  // fails and must surface as a raise naming the error, not a warning.
  let catalog = @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id="opencode",
    slots=[
      @llm.ModelSlot::ModelSlot(
        id="opencode/claude-sonnet-5",
        label="Claude",
        provider_id="opencode",
        model_id="claude-sonnet-5",
        port=@posoco.ScriptedModel([]),
      ),
    ],
  )
  let router = @llm.RouterModelPort::from_catalogs([catalog])
  let drifted = @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id="other",
    slots=[
      @llm.ModelSlot::ModelSlot(
        id="other/model",
        label="Other",
        provider_id="other",
        model_id="model",
        port=@posoco.ScriptedModel([]),
      ),
    ],
  )
  let failed : Result[Unit, @posoco.CompositionError] = Ok(
    apply_model_override(
      router,
      [drifted],
      model="other/model",
      effort="",
      label="cetas-headless",
    ),
  ) catch {
    error => Err(error)
  }
  match failed {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("--model 'other/model' switch failed"))
    _ => fail("a switch failure must raise")
  }
}

///|
async test "--model override routes the turn to the selected slot's model" {
  // Real assembly (platform → session → override → compose → turn) with two
  // distinct scripted models behind the two slots: the override must move
  // the ACTUAL model call off the persisted selection, not just the router
  // label. The persisted selection is slot-a; the run asks for slot-b.
  let fs = FakeFs()
  let home = @fs.tmpdir(prefix="cetas-headless-test-")
  fs.files[home + "/.cetas/settings.json"] = "{\"providers\":{\"opencode\":{\"api_key\":\"sk-zen-test\"}},\"model\":\"opencode/slot-a\"}"
  let platform = @cetas_core.build_cetas_platform(
    home~,
    cwd="/w",
    fs,
    permission_mode=@permission.Yolo,
  )
  let model_a = @posoco.ScriptedModel([
    @posoco.Respond(@posoco.tk_stop_response("from-a")),
  ])
  let model_b = @posoco.ScriptedModel([
    @posoco.Respond(@posoco.tk_stop_response("from-b")),
  ])
  @cetas_core.swap_platform_catalog(
    platform.catalogs,
    "opencode",
    @llm.ProviderModelCatalog::ProviderModelCatalog(provider_id="opencode", slots=[
      @llm.ModelSlot::ModelSlot(
        id="opencode/slot-a",
        label="A",
        provider_id="opencode",
        model_id="slot-a",
        port=model_a,
        thinking_efforts=["low", "high"],
        default_effort=None,
      ),
      @llm.ModelSlot::ModelSlot(
        id="opencode/slot-b",
        label="B",
        provider_id="opencode",
        model_id="slot-b",
        port=model_b,
        thinking_efforts=["low", "high"],
        default_effort=None,
      ),
    ]),
  )
  let session = @cetas_core.build_cetas_session(
    platform~,
    cwd="/w",
    label="cetas-headless-tests",
  )
  apply_model_override(
    session.router,
    platform.catalogs,
    model="opencode/slot-b",
    effort="",
    label="cetas-headless",
  )
  let agent = @cetas_core.compose_cetas_agent(session~)
  let (write_out, _out) = tk_sink()
  let failed = run_one_turn(
    agent~,
    session_id="cetas-e2e-routing",
    task="which model are you",
    jsonl=None,
    write_out~,
  )
  assert_false(failed)
  assert_eq(model_b.call_count(), 1)
  assert_eq(model_a.call_count(), 0)
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
