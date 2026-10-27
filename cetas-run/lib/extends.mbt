///|
/// Trait methods exposed for dot-syntax callers (repo convention, herdr
/// precedent) — tests drive `observer.on_event(...)` directly.
pub extend JsonlObserver with @posoco.Observer::{on_event}

///|
pub extend StreamPrinter with @posoco.Observer::{on_event}
