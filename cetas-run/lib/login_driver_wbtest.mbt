///|
async test "login driver failure never prints provider error secrets or persists credentials" {
  let fs = FakeFs()
  let notes : Array[String] = []
  let driver : LoginDriver = {
    login: fn(
      _provider,
      _auth_method,
      _settings,
      _device,
      _interaction,
      _prompt,
    ) raise {
      raise @posoco.CommandError::ExecutionFailed(
        "provider response raw-secret-fixture",
      )
    },
    refresh: fn(_provider, _device, _snapshot) {
      abort("failed auth must not refresh")
    },
  }
  let prompt = LoginPrompt(["oauth"])
  let result = try
    run_login_with_interactions(
      home="/login-home",
      provider="openai",
      fs~,
      interaction=prompt,
      prompt~,
      note=fn(text) { notes.push(text) },
      mint_device_id=fn() { "unused" },
      driver~,
    )
  catch {
    err => err.to_string()
  } noraise {
    _ => "unexpected success"
  }
  assert_true(result.contains("credentials were not saved"))
  assert_false(result.contains("raw-secret-fixture"))
  assert_eq(fs.files.length(), 0)
  assert_eq(notes.length(), 0)
}

///|
async test "login cancellation after authentication prevents save and refresh" {
  let fs = FakeFs()
  let prompt = LoginPrompt(["oauth"])
  let driver : LoginDriver = {
    login: fn(
      provider,
      auth_method,
      _settings,
      _device,
      _interaction,
      _prompt,
    ) {
      prompt.cancelled = true
      {
        provider_id: provider,
        login_method: auth_method,
        feedback: "unused",
        credential: login_oauth_fixture(),
      }
    },
    refresh: fn(_provider, _device, _snapshot) {
      abort("cancelled auth must not refresh")
    },
  }
  let result = try
    run_login_with_interactions(
      home="/login-home",
      provider="openai",
      fs~,
      interaction=prompt,
      prompt~,
      note=fn(_text) { () },
      mint_device_id=fn() { "unused" },
      driver~,
    )
  catch {
    err => err.to_string()
  } noraise {
    _ => "unexpected success"
  }
  assert_true(result.contains("cancelled"))
  assert_eq(fs.files.length(), 0)
}

///|
async test "login model selection written during refresh is preserved" {
  let fs = FakeFs()
  let probe = LoginProbe()
  let base = probe.driver()
  let driver : LoginDriver = {
    login: base.login,
    refresh: async fn(provider, device, snapshot) {
      @cetas_core.write_active_model_selection(
        fs,
        home="/login-home",
        @cetas_core.ActiveModelSelection::ActiveModelSelection(
          "other/model",
          effort="high",
        ),
      )
      (base.refresh)(provider, device, snapshot)
    },
  }
  let prompt = LoginPrompt(["api_key", "sk-test-secret-fixture"])
  run_login_with_interactions(
    home="/login-home",
    provider="openai",
    fs~,
    interaction=prompt,
    prompt~,
    note=fn(_text) { () },
    mint_device_id=fn() { "unused" },
    driver~,
  )
  guard @cetas_core.read_active_model_selection(fs, home="/login-home")
    is Some(selection) else {
    fail("concurrent model selection must survive")
  }
  assert_eq(selection.slot, "other/model")
  assert_eq(selection.effort, Some("high"))
}

///|
#cfg(target="native")
test "login native device mint produces UUID v4 compatible with shared host path" {
  let id = mint_login_device_id()
  assert_eq(id.length(), 36)
  assert_eq(id[8:9].to_owned(), "-")
  assert_eq(id[13:14].to_owned(), "-")
  assert_eq(id[14:15].to_owned(), "4")
  assert_true(["8", "9", "a", "b"].contains(id[19:20].to_owned()))
  assert_false(id == mint_login_device_id())
}

///|
priv struct LoginCallbackPrompt {
  callback : async (@oauth.AuthPromptRequest) -> String raise @oauth.OAuthError
}

///|
impl @oauth.AuthPromptInteraction for LoginCallbackPrompt with fn prompt(
  self,
  request,
) {
  (self.callback)(request)
}

///|
async test "login async prompt callback cancellation never saves or refreshes" {
  // Exercise provider selection, method selection, and an automatic-method
  // provider's secret prompt. Cancellation interrupts a suspended callback,
  // rather than relying on EOF or AuthInteraction::is_cancelled.
  for provider in ["", "openai", "deepseek"] {
    let fs = FakeFs()
    let probe = LoginProbe()
    let notes : Array[String] = []
    let entered : @aqueue.Queue[Unit] = @aqueue.Queue(kind=Unbounded)
    let cleaned_up = Ref(false)
    let completed = Ref(false)
    let prompt : LoginCallbackPrompt = {
      callback: async fn(_request) raise @oauth.OAuthError {
        defer {
          cleaned_up.val = true
        }
        entered.put(()) catch {
          _ => raise @oauth.OAuthError::Cancelled
        }
        @async.sleep(10000)
        "must-not-be-used-secret-fixture"
      },
    }
    @async.with_task_group() <| group => {
      let task = group.spawn(
        () => {
          run_login_with_interactions(
            home="/login-home",
            provider~,
            fs~,
            interaction=@oauth.NoopAuthInteraction(),
            prompt~,
            note=fn(text) { notes.push(text) },
            mint_device_id=fn() {
              abort("cancelled prompt must not mint device id")
            },
            driver=probe.driver(),
          )
          completed.val = true
        },
        allow_failure=true,
      )
      entered.get()
      task.cancel()
    }
    assert_true(cleaned_up.val)
    assert_false(completed.val)
    assert_eq(probe.snapshots.length(), 0)
    assert_eq(fs.files.length(), 0)
    assert_eq(notes.length(), 0)
  }
}

///|
async test "login inconsistent outcome uses bounded human method wording" {
  let fs = FakeFs()
  let prompt = LoginPrompt(["oauth"])
  let driver : LoginDriver = {
    login: fn(
      _provider,
      _auth_method,
      _settings,
      _device,
      _interaction,
      _prompt,
    ) {
      {
        provider_id: "raw-secret-fixture",
        login_method: "raw-secret-fixture",
        feedback: "unused",
        credential: login_oauth_fixture(),
      }
    },
    refresh: fn(_provider, _device, _snapshot) {
      abort("inconsistent outcome must not refresh")
    },
  }
  let result = try
    run_login_with_interactions(
      home="/login-home",
      provider="openai",
      fs~,
      interaction=prompt,
      prompt~,
      note=fn(_text) { () },
      mint_device_id=fn() { "unused" },
      driver~,
    )
  catch {
    err => err.to_string()
  } noraise {
    _ => "unexpected success"
  }
  assert_true(result.contains("inconsistent provider or method"))
  assert_false(result.contains("auth_method"))
  assert_false(result.contains("secret-fixture"))
  assert_eq(fs.files.length(), 0)
}
