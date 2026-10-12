///|
async test "models.dev store atomically persists a versioned cache separately from discovery" {
  let fs = FakeFs()
  fs.files["/cetas-home/.cetas/model_lists.json"] = "{\"untouched\":42}"
  let store = FileModelMetadataStore(fs, home="/cetas-home")
  assert_eq(store.read(), None)
  let payload : Json = {
    "version": 1,
    "providers": {
      "deepseek": {
        "fetched_at": "1000",
        "models": { "deepseek-flash": 1000000 },
      },
    },
  }
  store.write(payload)
  assert_eq(store.read(), Some(payload))
  assert_eq(
    fs.files["/cetas-home/.cetas/model_lists.json"],
    "{\"untouched\":42}",
  )
  fs.fail_ops["write_file_atomic"] = true
  try store.write({ "version": 2 }) catch {
    err => assert_true(err.to_string().contains("atomic"))
  } noraise {
    _ => fail("expected atomic write failure")
  }
  assert_eq(store.read(), Some(payload))
}

///|
async test "models.dev store exposes malformed and unreadable cache" {
  let fs = FakeFs()
  let store = FileModelMetadataStore(fs, home="/cetas-home")
  fs.files["/cetas-home/.cetas/models_dev.json"] = "{bad"
  try store.read() catch {
    _ => ()
  } noraise {
    _ => fail("expected malformed cache error")
  }
  fs.fail_ops["read_file"] = true
  try store.read() catch {
    _ => ()
  } noraise {
    _ => fail("expected unreadable cache error")
  }
}

///|
test "discovery cache retains capacity provenance and cannot promote fallback" {
  let slot = cache_slot("model-a", context_window=Some(500000))
  let fallback = { ..slot, context_window_source: "fallback", }
  let derived = catalog_model_records(tk_catalog([fallback]))
  assert_eq(@llm.cached_provider_context_window(Some(derived), "model-a"), None)
  let records = catalog_model_records(tk_catalog([slot]))
  assert_eq(
    @llm.cached_provider_context_window(
      Some(records),
      "model-a",
      metadata_provider_id="test",
    ),
    Some(500000),
  )
  assert_eq(
    @llm.cached_provider_context_window(
      Some(records),
      "model-a",
      metadata_provider_id="another-provider",
    ),
    None,
  )
}
