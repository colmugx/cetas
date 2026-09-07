///|
/// platform_wbtest.mbt — whitebox coverage for the relocated platform
/// pieces: session-id minting, the host sidecar, provider settings parsing,
/// and the platform assembly itself. Reuses the package's shared FakeFs.

///|
/// Silent warn sink with capture for assertions.
fn tk_capturing_warn(sink : Array[String]) -> async (String) -> Unit noraise {
  fn(message : String) { sink.push(message) }
}

///|
fn tk_durable_id_shape(id : String) -> Bool {
  if !id.has_prefix("cetas-") {
    return false
  }
  let tail = id.sub(start=6).to_owned()
  if tail.length() == 0 {
    return false
  }
  let mut ok = true
  for char in tail {
    match char {
      '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9' | '-' => ()
      _ => ok = false
    }
  }
  ok
}

///|
async test "session ids are clock-minted, validator-clean, and unique" {
  let ids : Array[String] = []
  for i = 0; i < 8; i = i + 1 {
    ids.push(mint_session_id())
  }
  for i = 0; i < ids.length(); i = i + 1 {
    assert_true(tk_durable_id_shape(ids[i]))
    // The id doubles as a JSONL file stem, so it must pass the store's filename check.
    assert_true(@fs_session.validate_session_id(ids[i]) is Ok(_))
    for j = i + 1; j < ids.length(); j = j + 1 {
      assert_false(ids[i] == ids[j])
    }
  }
}

///|
async test "sidecar round-trips fields, merges survival facts, and degrades on corruption" {
  let fs = FakeFs()
  let warnings : Array[String] = []
  update_session_sidecar(
    fs,
    home="/home",
    session_id="cetas-1",
    live_cwd="/w",
    model="p/m",
    effort=Some("high"),
    fresh_mcp_names=[],
    warn=tk_capturing_warn(warnings),
  )
  assert_eq(
    fs.files[sidecar_path("/home", "cetas-1")],
    "{\n  \"cwd\": \"/w\",\n  \"model\": \"p/m\",\n  \"effort\": \"high\",\n  \"mcp_servers\": []\n}\n",
  )
  // A refresh with no recorded roster seeds the fresh names; cwd survives.
  update_session_sidecar(
    fs,
    home="/home",
    session_id="cetas-1",
    live_cwd="/elsewhere",
    model="p/n",
    effort=None,
    fresh_mcp_names=["ghost"],
    warn=tk_capturing_warn(warnings),
  )
  let refreshed = read_session_sidecar(fs, home="/home", session_id="cetas-1")
  match refreshed {
    Some({ cwd, model, effort, mcp_servers, }) => {
      assert_eq(cwd, "/w")
      assert_eq(model, "p/n")
      assert_true(effort is None)
      assert_eq(mcp_servers, ["ghost"])
    }
    None => fail("the refreshed sidecar must read back")
  }
  // A corrupt file degrades to None with one warn; defaults restore.
  fs.files[sidecar_path("/home", "cetas-2")] = "{corrupt"
  let corrupt = read_session_sidecar(
    fs,
    home="/home",
    session_id="cetas-2",
    warn=tk_capturing_warn(warnings),
  )
  assert_true(corrupt is None)
  let mut saw_warn = false
  for message in warnings {
    if message.contains("session sidecar is not a JSON object") {
      saw_warn = true
    }
  }
  assert_true(saw_warn)
}

///|
async test "load_provider_settings parses the providers object and fails loudly on malformed content" {
  let fs = FakeFs()
  let missing = load_provider_settings(fs, home="/home")
  assert_eq(missing.length(), 0)
  fs.files["/home/.cetas/settings.json"] = "{\"providers\":{\"kimi\":{}},\"model\":\"kimi/x\"}"
  let parsed = load_provider_settings(fs, home="/home")
  assert_true(parsed.contains("kimi"))
  assert_false(parsed.contains("model"))
  fs.files["/home/.cetas/settings.json"] = "{corrupt"
  let malformed : Result[Map[String, Json], @posoco.CompositionError] = Ok(
    load_provider_settings(fs, home="/home"),
  ) catch {
    error => Err(error)
  }
  match malformed {
    Err(@posoco.CompositionError::ManifestSchemaError(..)) => ()
    _ => fail("malformed settings must fail composition")
  }
  fs.files["/home/.cetas/settings.json"] = "{\"providers\": []}"
  let wrong_shape : Result[Map[String, Json], @posoco.CompositionError] = Ok(
    load_provider_settings(fs, home="/home"),
  ) catch {
    error => Err(error)
  }
  match wrong_shape {
    Err(@posoco.CompositionError::ManifestSchemaError(..)) => ()
    _ => fail("a non-object providers body must fail composition")
  }
}

///|
async test "the platform assembly seeds catalogs from the model cache and swaps entries in place" {
  let fs = FakeFs()
  let warnings : Array[String] = []
  fs.files["/home/.cetas/settings.json"] = "{\"providers\":{\"opencode\":{\"api_key\":\"sk-zen-test\"}}}"
  fs.files["/home/.cetas/model_lists.json"] = "{\"opencode\":[{\"model_id\":\"claude-sonnet-5\",\"thinking_efforts\":[],\"default_effort\":null,\"context_window\":null},{\"model_id\":\"gpt-5.1-codex\",\"thinking_efforts\":[],\"default_effort\":null,\"context_window\":null}]}"
  let platform = build_cetas_platform(
    home="/home",
    cwd="/",
    fs,
    permission_mode=@permission.WorkspaceWrite,
    warn=tk_capturing_warn(warnings),
  )
  let router = build_cetas_router(platform~)
  assert_eq(router.list_slot_ids(), [
    "opencode/claude-sonnet-5", "opencode/gpt-5.1-codex",
  ])
  assert_true(platform.permission_mode is WorkspaceWrite)
  assert_eq(platform.default_slot_id, "")
  assert_true(platform.persisted_effort is None)
  // An unreadable cache warns and degrades to the static catalog.
  fs.files["/home/.cetas/model_lists.json"] = "{corrupt"
  let degraded = build_cetas_platform(
    home="/home",
    cwd="/",
    fs,
    permission_mode=@permission.WorkspaceWrite,
    warn=tk_capturing_warn(warnings),
  )
  let static_router = build_cetas_router(platform=degraded)
  assert_eq(static_router.list_slot_ids(), ["opencode/claude-sonnet-5"])
  let mut saw_cache_warn = false
  for message in warnings {
    if message.contains("model list cache unreadable") {
      saw_cache_warn = true
    }
  }
  assert_true(saw_cache_warn)
  // The lazy refresh swaps one provider's catalog in place.
  let swapped = @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id="opencode",
    slots=[
      @llm.ModelSlot::ModelSlot(
        id="opencode/fresh",
        label="Fresh",
        provider_id="opencode",
        model_id="fresh",
        port=@posoco.ScriptedModel([]),
      ),
    ],
  )
  swap_platform_catalog(degraded.catalogs, "opencode", swapped)
  assert_eq(degraded.catalogs[0].provider_id, "opencode")
  assert_eq(degraded.catalogs[0].slots()[0].id, "opencode/fresh")
  // A platform with no provider configured fails loudly.
  let empty_fs = FakeFs()
  empty_fs.files["/home/.cetas/settings.json"] = "{}"
  let failed : Result[CetasPlatform, @posoco.CompositionError] = Ok(
    build_cetas_platform(
      home="/home",
      cwd="/",
      empty_fs,
      permission_mode=@permission.WorkspaceWrite,
    ),
  ) catch {
    error => Err(error)
  }
  match failed {
    Err(@posoco.CompositionError::EmptyPort(message)) =>
      assert_true(message.contains("no configured model provider"))
    _ => fail("an empty provider roster must fail composition")
  }
}

///|
async test "the session assembly joins the host prompt suffix onto the cetas prompt" {
  let fs = FakeFs()
  fs.files["/home/.cetas/settings.json"] = "{\"providers\":{\"opencode\":{\"api_key\":\"sk-zen-test\"}}}"
  let platform = build_cetas_platform(
    home="/home",
    cwd="/w",
    fs,
    permission_mode=@permission.WorkspaceWrite,
  )
  let base = cetas_system_prompt(cwd="/w")
  let plain = build_cetas_session(platform~, cwd="/w", enable_nmem=false)
  assert_eq(plain.config.system_prompt, Some(base))
  let suffixed = build_cetas_session(
    platform~,
    cwd="/w",
    prompt_suffix=Some("## Delegated tasks"),
    enable_nmem=false,
  )
  assert_eq(
    suffixed.config.system_prompt,
    Some(base + "\n\n" + "## Delegated tasks"),
  )
}
