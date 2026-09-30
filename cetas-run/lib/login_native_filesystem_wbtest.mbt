///|
#cfg(target="native")
async test "login twice on real NativeWorkspaceFs reuses Kimi device path and replaces credentials" {
  @async.with_task_group() <| group => {
    let home = @fs.tmpdir(prefix="cetas-login-native-test-")
    group.add_defer(() => @fs.rmdir(home, recursive=true))
    let fs = @workspace.NativeWorkspaceFs()
    let dir = @cetas_core.cetas_dir(home)
    // Existing .cetas is normal for a shared home; device-id persistence must
    // not fail simply because another host created the directory first.
    fs.mkdir(dir, recursive=true)
    fs.write_file(@cetas_core.settings_path(home), "{\"unknown\":true}\n")
    let device_ids : Array[String] = []
    let minted = Ref(0)
    let probe = LoginProbe()
    let base = probe.driver()
    let notes : Array[String] = []
    let saved_settings : Array[String] = []
    for iteration in 0..<2 {
      let access = if iteration == 0 {
        "long-access-secret-fixture"
      } else {
        "short-secret-fixture"
      }
      let driver : LoginDriver = {
        login: fn(
          provider,
          auth_method,
          _settings,
          device_id,
          _interaction,
          _prompt,
        ) {
          device_ids.push(device_id)
          {
            provider_id: provider,
            login_method: auth_method,
            feedback: "unused",
            credential: @oauth.ProviderCredential::OAuth(
              @oauth.Credential::Credential(
                access_token=access,
                refresh_token="refresh-secret-fixture",
                expires_at=2147483647,
              ),
            ),
          }
        },
        // Rebuild from the real core credential snapshot; no auth, discovery,
        // quota, or generation requests are made by this synthetic driver.
        refresh: base.refresh,
      }
      let prompt = LoginPrompt(["oauth"])
      run_login_with_interactions(
        home~,
        provider="kimi",
        fs~,
        interaction=prompt,
        prompt~,
        note=fn(text) { notes.push(text) },
        mint_device_id=fn() raise @posoco.CommandError {
          minted.val += 1
          mint_login_device_id()
        },
        driver~,
      )
      let store = @credentials.FileProviderCredentialStore(
        fs,
        @cetas_core.credentials_path(home),
      )
      guard store.read("kimi")
        is Some(@oauth.ProviderCredential::OAuth(credential)) else {
        fail("canonical Kimi credential must round trip")
      }
      assert_true(credential.access_token == access)
      assert_true(credential.refresh_token == "refresh-secret-fixture")
      saved_settings.push(fs.read_file(@cetas_core.settings_path(home)))
      assert_eq(@fs.readdir(@cetas_core.credentials_path(home)), ["kimi.json"])
      assert_false(@fs.readdir(dir).any(fn(name) { name.contains(".tmp-") }))
    }
    assert_eq(minted.val, 1)
    assert_eq(device_ids.length(), 2)
    assert_eq(device_ids[0], device_ids[1])
    assert_eq(fs.read_file(dir + "/kimi_device_id"), device_ids[0])
    assert_eq(saved_settings[0], saved_settings[1])
    assert_true(saved_settings[1].contains("\"unknown\": true"))
    assert_eq(probe.snapshots.length(), 2)
    guard probe.snapshots[1].credentials.get("kimi")
      is Some(@oauth.ProviderCredential::OAuth(latest)) else {
      fail("second core snapshot must contain the replaced credential")
    }
    assert_true(latest.access_token == "short-secret-fixture")
    assert_login_notes_safe(notes)
  }
}
