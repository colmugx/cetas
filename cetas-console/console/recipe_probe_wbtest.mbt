///|
/// Composition-cost probe, gated by /tmp/cetas-ablate-ui-on: builds one
/// recipe subset (RECIPE_SUBSET, comma-separated; default the full native
/// recipe), one full production-shaped session over it, then the whole
/// console runtime. FRESH_CACHE=1 pre-seeds a fresh models.dev cache so the
/// lazy metadata refresh takes the restore path. External RSS sampling of
/// the test binary reads one plateau per step; the long parks catch async
/// landings. Diagnostic for the startup-memory attribution (see
/// cetas-native/UI_PARITY.md): the composition itself costs ~3.5 MB; the
/// models.dev fetch was the ~12 MB boot ramp, now lazy.
async fn recipe_probe_enabled() -> Bool {
  @fs.exists("/tmp/cetas-ablate-ui-on") catch {
    _ => false
  }
}

///|
async test "recipe cost probe" {
  if !(recipe_probe_enabled() catch { _ => false }) {
    return
  }
  @async.with_task_group(group => {
    let home = @fs.tmpdir(prefix="cetas-recipe-probe-")
    let fs_impl = @workspace.NativeWorkspaceFs()
    let fs : &@workspace.WorkspaceFs = fs_impl
    fs.mkdir(home + "/.cetas", recursive=true) catch {
      _ => ()
    }
    fs.write_file(
      home + "/.cetas/settings.json",
      "{\"providers\":{\"opencode\":{\"api_key\":\"sk-fixture\"}}}",
    ) catch {
      _ => ()
    }
    let cwd = @fs.tmpdir(prefix="cetas-recipe-probe-ws-")
    // Probe #7: a FRESH models.dev cache makes the metadata refresh take
    // the cache-restore path (no network fetch, no giant parse).
    if @coreenv.get_env_var("FRESH_CACHE") is Some(_) {
      let now_ms = @async.now()
      let payload = "{\"version\":1,\"providers\":{\"opencode\":{\"models\":{\"probe-model\":200000},\"fetched_at\":\"" +
        now_ms.to_string() +
        "\"}}}"
      fs.write_file(home + "/.cetas/models_dev.json", payload) catch {
        _ => ()
      }
    }
    println("MARK base")
    @async.sleep(1000)
    let subset : Array[String] = match @coreenv.get_env_var("RECIPE_SUBSET") {
      Some(value) => {
        let keys : Array[String] = []
        for part in value.split(",") {
          keys.push("\{part}")
        }
        keys
      }
      None => @cetas_core.cetas_recipe_keys("native")
    }
    let exts = build_compiled_recipe_features(names=subset, ctx={
      fs,
      cwd,
      home,
    })
    println("MARK recipe \{exts.length()}")
    @async.sleep(1000)
    let platform = @cetas_core.build_cetas_platform(
      home~,
      cwd~,
      fs,
      permission_mode=@permission.PermissionMode::Yolo,
    ) catch {
      error => abort("platform: " + error.to_string())
    }
    let hub = EventHub::new()
    let registry = UiRegistry::new()
    let ui_port : &@posoco.UiPort = HubUiPort::new(
      hub,
      registry,
      "recipe-probe-session",
      native_ui=true,
    )
    let approval : &@permission.ApprovalSource = UiBlockingApprovalSource::new(
      ui_port,
    )
    let plan_review = ConsolePlanReview::ConsolePlanReview(ui_port)
    let session = @cetas_core.build_cetas_session(
      platform~,
      cwd~,
      feature_exts=exts,
      ui=Some(ui_port),
      approval=Some(approval),
      events_exts=Some(fn(events) {
        [compose_plan_mode(events, plan_review, fs, cwd) as &@posoco.Extension]
      }),
      label="cetas-recipe-probe",
    ) catch {
      error => abort("session: " + error.to_string())
    }
    ignore(session)
    println("MARK session")
    @async.sleep(1200)
    let mcp_bridge = compose_mcp_bridge(fs, home, cwd, group, None, "probe")
    reserve_mcp_tool_names(mcp_bridge, session.base_defs)
    println("MARK mcpbridge")
    @async.sleep(1200)
    let observer = ConsoleObserver::new(
      hub,
      @cetas_core.mint_events_publisher(session.events, owner="probe"),
      "recipe-probe-session",
      "cetas-native/0.1",
      native_ui=true,
    )
    @async.sleep(1500)
    println("MARK observer")
    let speed_metrics = @stats.Stats()
    println("MARK stats")
    @async.sleep(800)
    let statusbar = @statusbar.StatusBar(events=Some(session.events))
    println("MARK statusbar")
    @async.sleep(800)
    seed_status(
      @cetas_core.mint_events_publisher(session.events, owner="probe"),
    )
    println("MARK seed")
    @async.sleep(800)
    let agent_b = @cetas_core.compose_cetas_agent(
      session~,
      tail_exts=[observer as &@posoco.Extension, speed_metrics, statusbar],
      runtime=Some(
        compose_mcp_runtime(mcp_bridge, session.router as &@posoco.ModelPort)
        as &@runtime.Runtime,
      ),
      runtime_group=None,
    )
    ignore(agent_b)
    println("MARK agent-observed")
    @async.sleep(1200)
    // Probe #6: no second platform; just a LONG park to catch any late
    // async landings from the first platform/session/agent.
    println("MARK longpark")
    @async.sleep(12000)
    // The full console runtime in isolation (fresh hub, fresh platform).
    let config = console_config(
      fs,
      home,
      "cetas-native",
      "cetas-native/0.1",
      native_ui=true,
      permission_mode=@permission.PermissionMode::Yolo,
    )
    let runtime = compose_console_runtime(config, cwd, group)
    runtime.attach_sink(fn(frame : String) { ignore(frame) })
    ignore(runtime.runtime_json())
    println("MARK console")
    @async.sleep(3500)
    runtime.shutdown_all()
    println("MARK done")
    ignore(group)
  })
}
