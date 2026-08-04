///|
test "JsUiPort wire encodes a structured render event" {
  let raw = ui_render_event_to_json({
    slot: @port.UiSlot::Status,
    key: "goal.progress",
    title: Some("Goal"),
    body: @port.UiBody::Progress(0.5),
    ttl_ms: Some(1000),
  })
  let json = @json.parse(raw)
  match json {
    Json::Object(event) => {
      assert_eq(event["type"], Json::string("ui_render"))
      match event["render"] {
        Json::Object(render) => {
          assert_eq(render["key"], Json::string("goal.progress"))
          assert_eq(render["ttl_ms"], Json::number(1000.0))
        }
        _ => fail("render must be an object")
      }
    }
    _ => fail("event must be an object")
  }
}

///|
test "JsUiPort wire decodes a correlated input response" {
  let response = decode_ui_response_event(
    "{\"type\":\"ui_response\",\"request_id\":\"ui-7\",\"response\":{\"type\":\"text\",\"text\":\"answer\"}}",
    "ui-7",
    @port.UiRequest::Input(prompt="Question", default=None),
  )
  match response {
    @port.UiResponse::Text(value) => assert_eq(value, "answer")
    _ => fail("expected text response")
  }
}

///|
test "JsUiPort wire rejects a response for another request" {
  try
    ignore(
      decode_ui_response_event(
        "{\"type\":\"ui_response\",\"request_id\":\"ui-8\",\"response\":{\"type\":\"yes\"}}",
        "ui-7",
        @port.UiRequest::Confirm(prompt="Continue?"),
      ),
    )
  catch {
    @error.UiError::InvalidRequest(detail=message) =>
      assert_eq(message, "ui_response.request_id does not match")
    _ => fail("expected UiError::HostError")
  } noraise {
    _ => fail("expected mismatched request id to fail")
  }
}

///|
/// `resolve_login_method` now lives in cetas-core; its provider-neutral
/// inference is tested there (provider_login_wbtest.mbt).

///|
test "model refresh selector validates provider ids and deduplicates requests" {
  match parse_refresh_provider_ids("") {
    None => ()
    Some(_) => fail("an empty selector must refresh all providers")
  }
  match parse_refresh_provider_ids("[\"kimi\",\"kimi\"]") {
    Some(ids) => {
      assert_eq(ids.length(), 1)
      assert_eq(ids[0], "kimi")
    }
    None => fail("an explicit selector must remain provider-scoped")
  }
  let unknown = Ok(parse_refresh_provider_ids("[\"unknown\"]")) catch {
    err => Err(err)
  }
  match unknown {
    Err(@posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~)) => {
      ignore(manifest_id)
      assert_true(detail.contains("no registered provider extension"))
    }
    _ => fail("unknown refresh providers must fail at the composition boundary")
  }
}

///|
/// The factory registry (provider/oauth/api_key/refreshable) now lives in
/// cetas-core and is covered by provider_login_wbtest.mbt there. The JS host
/// forwards to it, so this test is no longer host-specific.

///|
/// Remove an empty directory for white-box filesystem failure tests.
extern "js" fn bun_remove_dir_sync(path : String) -> Bool =
  #| (path) => { try { require("fs").rmdirSync(path); return true; } catch (error) { if (error?.code === "ENOENT") return true; return false; } }

///|
fn credential_test_store() -> JsProviderCredentialStore {
  let store = JsProviderCredentialStore::new(
    "/tmp/cetas-js-unified-credential-tests",
  )
  bun_mkdir_sync(store.cwd + "/.cetas/credentials")
  store
}

///|
fn clear_credential_test_files(
  store : JsProviderCredentialStore,
  provider_id : String,
) -> Unit {
  ignore(bun_delete_file(credential_path(store, provider_id)))
  ignore(bun_delete_file(legacy_api_key_credential_path(store, provider_id)))
  ignore(
    bun_remove_dir_sync(legacy_api_key_credential_path(store, provider_id)),
  )
}

///|
test "unified credential replacement preserves the explicitly selected method" {
  let store = credential_test_store()
  let provider_id = "credential-replacement"
  clear_credential_test_files(store, provider_id)
  let oauth = @oauth.Credential::Credential(
    access_token="oauth-access",
    refresh_token="oauth-refresh",
    expires_at=0,
  )
  let api_key = @oauth.ApiKeyCredential::ApiKeyCredential(
    secret="api-key-secret",
  )
  persist_provider_credential(
    store,
    provider_id,
    @oauth.ProviderCredential::OAuth(oauth),
  ) catch {
    err => fail("OAuth write failed: " + @cetas_core.oauth_error_text(err))
  }
  persist_provider_credential(
    store,
    provider_id,
    @oauth.ProviderCredential::ApiKey(api_key),
  ) catch {
    err => fail("API-key write failed: " + @cetas_core.oauth_error_text(err))
  }
  let selected = read_provider_credential(store, provider_id)
  match selected {
    Some(value) => assert_eq(value.method_id(), "api_key")
    None => fail("expected API-key credential after replacement")
  }
  persist_provider_credential(
    store,
    provider_id,
    @oauth.ProviderCredential::OAuth(oauth),
  ) catch {
    err => fail("OAuth rewrite failed: " + @cetas_core.oauth_error_text(err))
  }
  let selected_again = read_provider_credential(store, provider_id)
  match selected_again {
    Some(value) => assert_eq(value.method_id(), "oauth")
    None => fail("expected OAuth credential after replacement")
  }
  clear_credential_test_files(store, provider_id)
}

///|
test "legacy single-source records migrate with the tagged envelope" {
  let store = credential_test_store()
  let oauth_provider = "legacy-oauth-only"
  clear_credential_test_files(store, oauth_provider)
  let oauth = @oauth.Credential::Credential(
    access_token="legacy-oauth-access",
    refresh_token="legacy-oauth-refresh",
    expires_at=0,
  )
  let oauth_path = credential_path(store, oauth_provider)
  ignore(bun_write_file_atomic(oauth_path, oauth.to_json().stringify()))
  let migrated = read_provider_credential(store, oauth_provider)
  match migrated {
    Some(value) => assert_eq(value.method_id(), "oauth")
    None => fail("expected legacy OAuth migration")
  }
  let canonical = match read_file_sync(oauth_path) {
    Content(value) => value
    _ => fail("expected migrated canonical record")
  }
  assert_true(canonical.contains("\"method\":\"oauth\""))
  assert_true(canonical.contains("\"credential\""))
  clear_credential_test_files(store, oauth_provider)

  let api_provider = "legacy-api-only"
  clear_credential_test_files(store, api_provider)
  let api = @oauth.ApiKeyCredential::ApiKeyCredential(
    secret="legacy-api-secret",
  )
  let legacy_path = legacy_api_key_credential_path(store, api_provider)
  ignore(bun_write_file_atomic(legacy_path, api.to_json().stringify()))
  let migrated_api = read_provider_credential(store, api_provider)
  match migrated_api {
    Some(value) => assert_eq(value.method_id(), "api_key")
    None => fail("expected legacy API-key migration")
  }
  let api_canonical = match
    read_file_sync(credential_path(store, api_provider)) {
    Content(value) => value
    _ => fail("expected migrated API-key canonical record")
  }
  assert_true(api_canonical.contains("\"method\":\"api_key\""))
  assert_true(api_canonical.contains("\"credential\""))
  clear_credential_test_files(store, api_provider)
}

///|
test "legacy OAuth plus API-key records fail with typed ambiguity and no secret leak" {
  let store = credential_test_store()
  let provider_id = "legacy-ambiguous"
  clear_credential_test_files(store, provider_id)
  let oauth = @oauth.Credential::Credential(
    access_token="ambiguous-oauth-secret",
    refresh_token="ambiguous-refresh-secret",
    expires_at=0,
  )
  let api = @oauth.ApiKeyCredential::ApiKeyCredential(
    secret="ambiguous-api-secret",
  )
  ignore(
    bun_write_file_atomic(
      credential_path(store, provider_id),
      oauth.to_json().stringify(),
    ),
  )
  ignore(
    bun_write_file_atomic(
      legacy_api_key_credential_path(store, provider_id),
      api.to_json().stringify(),
    ),
  )
  let result = Ok(read_provider_credential(store, provider_id)) catch {
    err => Err(err)
  }
  match result {
    Err(@posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~)) => {
      ignore(manifest_id)
      assert_true(detail.contains("ambiguous credentials"))
      assert_true(!detail.contains("ambiguous-oauth-secret"))
      assert_true(!detail.contains("ambiguous-api-secret"))
    }
    _ => fail("expected typed credential ambiguity")
  }
  // Explicit login persistence replaces the canonical record and recovers
  // setup without guessing; post-write cleanup removes the old sidecar.
  persist_provider_credential(
    store,
    provider_id,
    @oauth.ProviderCredential::ApiKey(api),
  ) catch {
    err =>
      fail(
        "explicit recovery write failed: " + @cetas_core.oauth_error_text(err),
      )
  }
  match read_provider_credential(store, provider_id) {
    Some(value) => assert_eq(value.method_id(), "api_key")
    None => fail("expected explicit recovery credential")
  }
  match read_file_sync(legacy_api_key_credential_path(store, provider_id)) {
    Missing => ()
    _ => fail("explicit recovery must remove the legacy sidecar")
  }
  clear_credential_test_files(store, provider_id)
}

///|
test "legacy sidecar cleanup failure is visible and retried on read" {
  let store = credential_test_store()
  let provider_id = "cleanup-retry"
  clear_credential_test_files(store, provider_id)
  let api = @oauth.ApiKeyCredential::ApiKeyCredential(secret="cleanup-secret")
  let legacy_path = legacy_api_key_credential_path(store, provider_id)
  // A directory at the sidecar path makes unlink fail without destroying the
  // canonical file written immediately before cleanup.
  bun_mkdir_sync(legacy_path)
  let write_result = Ok(
    persist_provider_credential(
      store,
      provider_id,
      @oauth.ProviderCredential::ApiKey(api),
    ),
  ) catch {
    err => Err(err)
  }
  match write_result {
    Err(@oauth.OAuthError::HttpError(detail)) =>
      assert_true(detail.contains("legacy credential cleanup failed"))
    _ => fail("cleanup failure must be observable after canonical write")
  }
  match read_file_sync(credential_path(store, provider_id)) {
    Content(value) => assert_true(value.contains("\"method\":\"api_key\""))
    _ => fail("canonical credential must survive sidecar cleanup failure")
  }
  let read_result = Ok(read_provider_credential(store, provider_id)) catch {
    err => Err(err)
  }
  match read_result {
    Err(@posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~)) => {
      ignore(manifest_id)
      assert_true(detail.contains("legacy credential cleanup failed"))
      assert_true(!detail.contains("cleanup-secret"))
    }
    _ => fail("read must retry cleanup and surface a typed failure")
  }
  assert_true(bun_remove_dir_sync(legacy_path))
  match read_provider_credential(store, provider_id) {
    Some(value) => assert_eq(value.method_id(), "api_key")
    None => fail("read should recover once cleanup becomes possible")
  }
  match read_file_sync(legacy_path) {
    Missing => ()
    _ => fail("successful retry must remove the legacy sidecar")
  }
  clear_credential_test_files(store, provider_id)
}

///|
async test "canonical delete removes legacy sidecar without resurrection" {
  let store = credential_test_store()
  let provider_id = "delete-no-resurrection"
  clear_credential_test_files(store, provider_id)
  let api = @oauth.ApiKeyCredential::ApiKeyCredential(secret="delete-secret")
  persist_provider_credential(
    store,
    provider_id,
    @oauth.ProviderCredential::ApiKey(api),
  ) catch {
    err => fail("canonical write failed: " + @cetas_core.oauth_error_text(err))
  }
  // Reintroduce an old sidecar after the canonical write to model an old
  // process racing with logout. Delete must remove both sources.
  ignore(
    bun_write_file_atomic(
      legacy_api_key_credential_path(store, provider_id),
      api.to_json().stringify(),
    ),
  )
  let delete_result = Ok(store.delete(provider_id)) catch { err => Err(err) }
  match delete_result {
    Ok(_) => ()
    Err(err) =>
      fail("canonical delete failed: " + @cetas_core.oauth_error_text(err))
  }
  match read_file_sync(credential_path(store, provider_id)) {
    Missing => ()
    _ => fail("canonical credential must be deleted")
  }
  match read_file_sync(legacy_api_key_credential_path(store, provider_id)) {
    Missing => ()
    _ => fail("logout must remove the legacy sidecar")
  }
  match read_provider_credential(store, provider_id) {
    None => ()
    Some(_) => fail("deleted credentials must not resurrect from a sidecar")
  }
  clear_credential_test_files(store, provider_id)
}

///|
async test "logout cleanup failure keeps canonical credential for retry" {
  let store = credential_test_store()
  let provider_id = "delete-cleanup-retry"
  clear_credential_test_files(store, provider_id)
  let api = @oauth.ApiKeyCredential::ApiKeyCredential(
    secret="delete-retry-secret",
  )
  persist_provider_credential(
    store,
    provider_id,
    @oauth.ProviderCredential::ApiKey(api),
  ) catch {
    err => fail("canonical write failed: " + @cetas_core.oauth_error_text(err))
  }
  let legacy_path = legacy_api_key_credential_path(store, provider_id)
  bun_mkdir_sync(legacy_path)
  let delete_result = Ok(store.delete(provider_id)) catch { err => Err(err) }
  match delete_result {
    Err(@oauth.OAuthError::HttpError(detail)) =>
      assert_true(detail.contains("legacy credential cleanup failed"))
    _ => fail("logout cleanup failure must be observable")
  }
  match read_file_sync(credential_path(store, provider_id)) {
    Content(value) => assert_true(value.contains("\"method\":\"api_key\""))
    _ => fail("failed logout must leave canonical credential intact")
  }
  assert_true(bun_remove_dir_sync(legacy_path))
  store.delete(provider_id) catch {
    err => fail("logout retry failed: " + @cetas_core.oauth_error_text(err))
  }
  match read_provider_credential(store, provider_id) {
    None => ()
    Some(_) => fail("successful logout retry must not resurrect credentials")
  }
  clear_credential_test_files(store, provider_id)
}
