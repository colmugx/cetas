///|
/// The async stderr handle is single-writer; serialize diagnostics so provider
/// setup and session failures cannot overlap and panic the stream wrapper.
let memoh_stderr_lock : @async.Mutex = @async.Mutex::Mutex()

///|
pub async fn memoh_warn(message : String) -> Unit noraise {
  memoh_stderr_lock.acquire()
  defer memoh_stderr_lock.release()
  @stdio.stderr.write(message) catch {
    _ => ()
  }
}
