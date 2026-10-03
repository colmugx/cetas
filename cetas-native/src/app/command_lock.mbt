/// Framework-free command-busy gate for native product flows.
///
/// This mirrors cetas-js CommandLock semantics exactly:
/// - acquire always re-arms, including nested/repeated acquires;
/// - the latest label replaces the previous acquire label;
/// - release is idempotent and only the first release after an acquire
///   reports a transition.
///
/// Side effects such as editor submit-disable or status text remain owned by
/// NativeAppLoop; this reducer only owns the deterministic lock state.

///|
pub struct CommandLockModel {
  mut held : Bool
  mut label : String?
}

///|
pub fn CommandLockModel::new() -> CommandLockModel {
  { held: false, label: None, }
}

///|
pub fn CommandLockModel::is_held(self : CommandLockModel) -> Bool {
  self.held
}

///|
pub fn CommandLockModel::label(self : CommandLockModel) -> String? {
  self.label
}

///|
pub fn CommandLockModel::acquire(
  self : CommandLockModel,
  label : String,
) -> Unit {
  self.held = true
  self.label = Some(label)
}

///|
/// True only when this call transitions held -> released.
pub fn CommandLockModel::release(self : CommandLockModel) -> Bool {
  if !self.held {
    return false
  }
  self.held = false
  self.label = None
  true
}

///|
pub fn command_lock_validation_marker() -> Int {
  let lock = CommandLockModel::new()
  if lock.is_held() || lock.label() is Some(_) {
    return 0
  }

  lock.acquire("loading model catalog")
  if !lock.is_held() || lock.label() != Some("loading model catalog") {
    return 0
  }

  // Re-acquire is not reference counting. It re-arms and refreshes the label.
  lock.acquire("authenticating github")
  if !lock.is_held() || lock.label() != Some("authenticating github") {
    return 0
  }

  if !lock.release() || lock.is_held() || lock.label() is Some(_) {
    return 0
  }

  // Duplicate release is a no-op.
  if lock.release() {
    return 0
  }

  lock.acquire("again")
  if !lock.is_held() || !lock.release() || lock.is_held() {
    return 0
  }

  1
}
