///|
/// Tool extensions contributed by a local build, placed in the deferred
/// (lazytools-behind) bucket by every host that calls this.
///
/// The public composition is exactly the checked-in compiled recipe, so the
/// default implementation contributes nothing. A local build may swap this
/// package for its own wiring; the seam, not the wiring, is public.
pub fn deferred_extensions(
  host_group : @async.TaskGroup[Unit]?,
) -> Array[&@posoco.Extension] {
  let _ = host_group
  let none : Array[&@posoco.Extension] = []
  none
}
