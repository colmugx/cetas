///|
priv struct LoginPrompt {
  answers : Array[String]
  requests : Array[@oauth.AuthPromptRequest]
  mut cursor : Int
  mut cancelled : Bool
}

///|
fn LoginPrompt::LoginPrompt(answers : Array[String]) -> LoginPrompt {
  { answers, requests: [], cursor: 0, cancelled: false, }
}

///|
impl @oauth.AuthInteraction for LoginPrompt with fn notify(_self, _message) {

}

///|
impl @oauth.AuthInteraction for LoginPrompt with fn is_cancelled(self) {
  self.cancelled
}

///|
impl @oauth.AuthPromptInteraction for LoginPrompt with fn prompt(self, request) {
  self.requests.push(request)
  if self.cursor >= self.answers.length() {
    raise @oauth.OAuthError::Cancelled
  }
  let answer = self.answers[self.cursor]
  self.cursor += 1
  answer
}

///|
priv struct LoginProbe {
  credential : @oauth.ProviderCredential?
  fail_refresh : Bool
  cached_models : Json?
  calls : Array[String]
  snapshots : Array[@cetas_core.ProviderCredentialSnapshot]
}

///|
fn LoginProbe::LoginProbe(
  credential? : @oauth.ProviderCredential? = None,
  fail_refresh? : Bool = false,
  cached_models? : Json? = None,
) -> LoginProbe {
  { credential, fail_refresh, cached_models, calls: [], snapshots: [], }
}

///|
fn LoginProbe::driver(self : LoginProbe) -> LoginDriver {
  {
    login: async fn(
      provider,
      auth_method,
      settings,
      device_id,
      interaction,
      prompt,
    ) {
      self.calls.push("login:" + provider + ":" + auth_method)
      match self.credential {
        Some(credential) =>
          {
            provider_id: provider,
            login_method: auth_method,
            feedback: "DO NOT PRINT PROVIDER FEEDBACK secret-fixture",
            credential,
          }
        None =>
          @cetas_core.login_provider(
            provider,
            auth_method,
            settings~,
            device_id~,
            interaction,
            prompt,
          )
      }
    },
    refresh: fn(provider, _device_id, snapshot) raise {
      self.calls.push("refresh:" + provider)
      self.snapshots.push(snapshot)
      if self.fail_refresh {
        raise @posoco.CommandError::ExecutionFailed(
          "refresh error secret-fixture",
        )
      }
      for
        factory in @cetas_core.all_provider_factories(
          @devkit.ExtContext::default(),
          snapshot.settings,
        ) {
        if factory.provider_id() == provider {
          return @cetas_core.build_provider_catalog(
            factory,
            snapshot,
            cached_models=self.cached_models,
          )
        }
      }
      None
    },
  }
}

///|
async fn login_fixture(
  fs : &@workspace.WorkspaceFs,
  prompt : LoginPrompt,
  probe : LoginProbe,
  notes : Array[String],
  provider? : String = "openai",
) -> Unit {
  run_login_with_interactions(
    home="/login-home",
    provider~,
    fs~,
    interaction=prompt,
    prompt~,
    note=fn(text) { notes.push(text) },
    mint_device_id=fn() { "00112233-4455-4677-8899-aabbccddeeff" },
    driver=probe.driver(),
  )
}

///|
fn login_oauth_fixture() -> @oauth.ProviderCredential {
  @oauth.ProviderCredential::OAuth(
    @oauth.Credential::Credential(
      access_token="access-secret-fixture",
      refresh_token="refresh-secret-fixture",
      expires_at=2147483647,
      metadata=Map::from_array([("account_id", "test-account")]),
    ),
  )
}

///|
fn assert_login_notes_safe(notes : Array[String]) -> Unit raise {
  for note in notes {
    assert_false(note.contains("secret-fixture"))
    assert_false(note.contains("sk-test"))
    assert_false(note.contains("DO NOT PRINT"))
  }
}

///|
async test "login OpenAI OAuth canonical record round trips through core snapshot" {
  let fs = FakeFs()
  let probe = LoginProbe(credential=Some(login_oauth_fixture()))
  let prompt = LoginPrompt(["oauth"])
  let notes : Array[String] = []
  login_fixture(fs, prompt, probe, notes)
  assert_eq(probe.calls, ["login:openai:oauth", "refresh:openai"])
  assert_true(fs.files.contains("/login-home/.cetas/credentials/openai.json"))
  assert_false(
    fs.files.contains("/login-home/.cetas/credentials/openai-codex.json"),
  )
  guard probe.snapshots[0].credentials.get("openai")
    is Some(@oauth.ProviderCredential::OAuth(credential)) else {
    fail("OAuth credential must survive the core snapshot")
  }
  assert_eq(credential.access_token, "access-secret-fixture")
  assert_eq(credential.refresh_token, "refresh-secret-fixture")
  assert_eq(credential.metadata.get("account_id"), Some("test-account"))
  assert_true(probe.snapshots[0].credential_store is Some(_))
  assert_true(fs.files.contains("/login-home/.cetas/model_lists.json"))
  assert_true(
    @cetas_core.read_active_model_selection(fs, home="/login-home") is Some(_),
  )
  assert_login_notes_safe(notes)
}

///|
async test "login OpenAI key and DeepSeek key round trip using real core login and snapshots" {
  for provider in ["openai", "deepseek"] {
    let fs = FakeFs()
    let probe = LoginProbe()
    let prompt = LoginPrompt(
      if provider == "openai" {
        ["api_key", "sk-test-secret-fixture"]
      } else {
        ["sk-test-secret-fixture"]
      },
    )
    let notes : Array[String] = []
    login_fixture(fs, prompt, probe, notes, provider~)
    assert_eq(probe.calls, [
      "login:" + provider + ":api_key",
      "refresh:" + provider,
    ])
    guard probe.snapshots[0].credentials.get(provider)
      is Some(@oauth.ProviderCredential::ApiKey(credential)) else {
      fail("API key must survive the core snapshot")
    }
    assert_eq(credential.secret, "sk-test-secret-fixture")
    let store = @credentials.FileProviderCredentialStore(
      fs,
      @cetas_core.credentials_path("/login-home"),
    )
    guard store.read(provider)
      is Some(@oauth.ProviderCredential::ApiKey(stored)) else {
      fail("canonical store must read the saved key")
    }
    assert_eq(stored.secret, credential.secret)
    // DeepSeek has one auth capability and must skip the method selector.
    assert_eq(
      prompt.requests.length(),
      if provider == "openai" {
        2
      } else {
        1
      },
    )
    assert_login_notes_safe(notes)
  }
}

///|
async test "login selects provider and method before any provider is model ready" {
  let fs = FakeFs()
  let probe = LoginProbe()
  let prompt = LoginPrompt(["openai", "api_key", "sk-test-secret-fixture"])
  login_fixture(fs, prompt, probe, [], provider="")
  guard prompt.requests[0] is @oauth.AuthPromptRequest::Select(options~, ..) else {
    fail("missing provider picker")
  }
  assert_true(options.any(fn(option) { option.id == "openai" }))
  assert_true(options.any(fn(option) { option.id == "kimi" }))
  assert_eq(probe.calls[0], "login:openai:api_key")
  guard prompt.requests[1] is @oauth.AuthPromptRequest::Select(message~, ..) else {
    fail("missing authentication method picker")
  }
  assert_eq(message, "Select authentication method")
}

///|
async test "login preserves pending model effort and unrelated settings byte for byte" {
  let fs = FakeFs()
  let settings = "{\"model\":\"missing-provider/model\",\"reasoning_effort\":\"high\",\"unknown\":{\"keep\":true}}\n"
  fs.files["/login-home/.cetas/settings.json"] = settings
  let probe = LoginProbe()
  let prompt = LoginPrompt(["api_key", "sk-test-secret-fixture"])
  login_fixture(fs, prompt, probe, [])
  assert_eq(fs.files["/login-home/.cetas/settings.json"], settings)
  assert_eq(prompt.requests.length(), 2)
}

///|
async test "login refresh failure retains successful auth and reports truthful bounded error" {
  let fs = FakeFs()
  let probe = LoginProbe(fail_refresh=true)
  let notes : Array[String] = []
  let result = try
    login_fixture(
      fs,
      LoginPrompt(["api_key", "sk-test-secret-fixture"]),
      probe,
      notes,
    )
  catch {
    err => err.to_string()
  } noraise {
    _ => "unexpected success"
  }
  assert_true(result.contains("Authentication saved"))
  assert_true(result.contains("catalog refresh failed"))
  assert_false(result.contains("secret-fixture"))
  assert_true(fs.files.contains("/login-home/.cetas/credentials/openai.json"))
  assert_false(fs.files.contains("/login-home/.cetas/settings.json"))
  assert_false(fs.files.contains("/login-home/.cetas/model_lists.json"))
  assert_login_notes_safe(notes)
}

///|
async test "login picker and secret prompt cancellation never save or refresh" {
  for answers in [[], ["api_key"]] {
    let fs = FakeFs()
    let probe = LoginProbe()
    let notes : Array[String] = []
    let result = try
      login_fixture(fs, LoginPrompt(answers), probe, notes)
    catch {
      err => err.to_string()
    } noraise {
      _ => "unexpected success"
    }
    assert_true(result.contains("cancelled"))
    assert_eq(probe.snapshots.length(), 0)
    assert_eq(fs.files.length(), 0)
    assert_eq(notes.length(), 0)
  }
}

///|
async test "login unknown provider and invalid method do not echo pasted secrets" {
  for
    (provider, answers) in [
      ("raw-secret-fixture", []),
      ("openai", ["raw-secret-fixture"]),
    ] {
    let fs = FakeFs()
    let probe = LoginProbe()
    let result = try
      login_fixture(fs, LoginPrompt(answers), probe, [], provider~)
    catch {
      err => err.to_string()
    } noraise {
      _ => "unexpected success"
    }
    assert_false(result.contains("secret-fixture"))
    assert_false(result.contains("unexpected success"))
    assert_eq(probe.calls.length(), 0)
    assert_eq(fs.files.length(), 0)
  }
}

///|
async test "login shared Kimi device path is stable and trims existing host file" {
  let fs = FakeFs()
  fs.files["/login-home/.cetas/kimi_device_id"] = "existing-host-id\n"
  let existing = login_device_id(fs, "/login-home", fn() {
    abort("must reuse existing id")
  })
  assert_eq(existing, "existing-host-id")
  ignore(fs.files.remove("/login-home/.cetas/kimi_device_id"))
  let minted = login_device_id(fs, "/login-home", fn() { "test-stable-id" })
  assert_eq(minted, "test-stable-id")
  assert_eq(login_device_id(fs, "/login-home", fn() { "not-used" }), minted)
}

///|
async test "login cancellation flag stops automatic method before authentication" {
  let fs = FakeFs()
  let probe = LoginProbe()
  let prompt = LoginPrompt([])
  prompt.cancelled = true
  let result = try
    login_fixture(fs, prompt, probe, [], provider="deepseek")
  catch {
    err => err.to_string()
  } noraise {
    _ => "unexpected success"
  }
  assert_true(result.contains("cancelled"))
  assert_eq(probe.calls.length(), 0)
  assert_eq(fs.files.length(), 0)
}

///|
async test "login model picker saves choice and preserves unrelated cache and settings" {
  let fs = FakeFs()
  fs.files["/login-home/.cetas/settings.json"] = "{\"unknown\":true,\"providers\":{}}"
  fs.files["/login-home/.cetas/model_lists.json"] = "{\"other\":[{\"model_id\":\"keep\"}]}"
  // Records round trip through `catalog_model_records`, whose contract now
  // carries the slot's `use_responses_lite` capability beside `image_in`.
  let records = @json.parse(
    "[{\"model_id\":\"gpt-4o\",\"thinking_efforts\":[],\"default_effort\":null,\"context_window\":null,\"image_in\":false,\"use_responses_lite\":false},{\"model_id\":\"gpt-4.1\",\"thinking_efforts\":[],\"default_effort\":null,\"context_window\":null,\"image_in\":false,\"use_responses_lite\":false}]",
  )
  let probe = LoginProbe(cached_models=Some(records))
  let prompt = LoginPrompt([
    "api_key", "sk-test-secret-fixture", "openai/gpt-4.1",
  ])
  login_fixture(fs, prompt, probe, [])
  guard @cetas_core.read_active_model_selection(fs, home="/login-home")
    is Some(selection) else {
    fail("model selection was not persisted")
  }
  assert_eq(selection.slot, "openai/gpt-4.1")
  assert_true(
    fs.files["/login-home/.cetas/settings.json"].contains("\"unknown\": true"),
  )
  guard @cetas_core.read_model_list_cache(fs, home="/login-home") is Ok(cache) else {
    fail("cache must round trip")
  }
  assert_true(cache.contains("other"))
  assert_eq(cache.get("openai"), Some(records))
}

///|
async test "login cancelled model picker retains saved authentication and refreshed cache" {
  let fs = FakeFs()
  let probe = LoginProbe(
    cached_models=Some(
      @json.parse(
        "[{\"model_id\":\"gpt-4o\",\"thinking_efforts\":[],\"default_effort\":null},{\"model_id\":\"gpt-4.1\",\"thinking_efforts\":[],\"default_effort\":null}]",
      ),
    ),
  )
  let result = try
    login_fixture(
      fs,
      LoginPrompt(["api_key", "sk-test-secret-fixture"]),
      probe,
      [],
    )
  catch {
    err => err.to_string()
  } noraise {
    _ => "unexpected success"
  }
  assert_true(result.contains("cancelled"))
  assert_true(fs.files.contains("/login-home/.cetas/credentials/openai.json"))
  assert_true(fs.files.contains("/login-home/.cetas/model_lists.json"))
  assert_false(fs.files.contains("/login-home/.cetas/settings.json"))
}

///|
async test "login static custom provider uses core capabilities and production driver without network" {
  let fs = FakeFs()
  fs.files["/login-home/.cetas/settings.json"] = "{\"providers\":{\"custom\":{\"base_url\":\"https://example.invalid/v1\",\"model\":\"test-model\"}}}"
  let prompt = LoginPrompt(["sk-test-secret-fixture"])
  run_login_with_interactions(
    home="/login-home",
    provider="custom",
    fs~,
    interaction=prompt,
    prompt~,
    note=fn(_text) { () },
    mint_device_id=fn() { abort("API-key login must not mint a device id") },
  )
  assert_eq(prompt.requests.length(), 1)
  assert_true(fs.files.contains("/login-home/.cetas/credentials/custom.json"))
  guard @cetas_core.read_active_model_selection(fs, home="/login-home")
    is Some(selection) else {
    fail("static catalog should select the single model")
  }
  assert_eq(selection.slot, "custom/test-model")
}
