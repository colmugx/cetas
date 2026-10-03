///|
test "native command lock mirrors acquire and idempotent release semantics" {
  let lock = CommandLockModel::new()
  assert_false(lock.is_held())
  assert_true(lock.label() is None)

  lock.acquire("loading model catalog")
  assert_true(lock.is_held())
  assert_true(lock.label() == Some("loading model catalog"))

  assert_true(lock.release())
  assert_false(lock.is_held())
  assert_true(lock.label() is None)

  assert_false(lock.release())
  assert_false(lock.is_held())
}

///|
test "native command lock tolerates double acquire and releases fully once" {
  let lock = CommandLockModel::new()

  lock.acquire("provider picker")
  lock.acquire("authenticating github")
  assert_true(lock.is_held())
  assert_true(lock.label() == Some("authenticating github"))

  assert_true(lock.release())
  assert_false(lock.is_held())
  assert_true(lock.label() is None)
  assert_false(lock.release())

  lock.acquire("next command")
  assert_true(lock.is_held())
  assert_true(lock.release())
  assert_false(lock.is_held())
}
