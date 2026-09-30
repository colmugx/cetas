///|
/// Publish a complete minimal config without touching an existing directory
/// entry (including symlinks). The staging file is on the same filesystem,
/// owner-only and exclusively created. No-replace rename arbitrates competing
/// starters; a losing starter removes only its own staging file.
/// Returns true only for the invocation that published settings.
async fn create_minimal_settings(dir : String, path : String) -> Bool {
  // Cancellation cannot interrupt publication after rename but before the
  // cleanup flag is set, nor leave an exclusively-created staging file behind.
  @async.protect_from_cancel(() => create_minimal_settings_protected(dir, path))
}

///|
async fn create_minimal_settings_protected(dir : String, path : String) -> Bool {
  try @fs.kind(path, follow_symlink=false) catch {
    @os_error.OSError(_) as err if err.is_ENOENT() => ()
    err => raise err
  } noraise {
    _ => return false
  }
  @fs.mkdir(dir, permission=0o700, recursive=true, allow_exist=true)
  let (staging, file) = for ;; {
    let staging = path + ".bootstrap-" + @cetas_core.mint_session_id()
    try
      @fs.open(staging, mode=WriteOnly, create_mode=CreateNew, permission=0o600)
    catch {
      @os_error.OSError(_) as err if err.is_EEXIST() => continue
      err => raise err
    } noraise {
      file => break (staging, file)
    }
  }
  let mut published = false
  defer (if !published { @fs.remove(staging) })
  {
    defer file.close()
    file.write("{\"providers\":{}}\n")
    file.sync()
  }
  try @fs.rename(staging, path, replace=false) catch {
    @os_error.OSError(_) as err if err.is_EEXIST() => false
    err => raise err
  } noraise {
    _ => {
      published = true
      true
    }
  }
}

///|
/// Startup ordering seam. Help/version return before even calling the creator.
/// For every other invocation bootstrap precedes argument error reporting and
/// stdin. The creator returns true iff it atomically created a complete file;
/// errors propagate (never interpreted as missing config). Diagnostics have
/// only a stderr sink, keeping answer/JSONL stdout untouched.
pub async fn prepare_invocation(
  argv : Array[String],
  home~ : String,
  native~ : Bool,
  create_settings? : async (String, String) -> Bool = create_minimal_settings,
  note~ : async (String) -> Unit noraise,
) -> Result[InvocationAction, String] {
  let action = parse_invocation(argv)
  match action {
    Ok(Help) | Ok(Version) => return action
    _ => ()
  }
  let path = @cetas_core.settings_path(home)
  let created = create_settings(@cetas_core.cetas_dir(home), path)
  if created {
    note(onboarding_guide(path, native~))
  } else if argv.is_empty() {
    note(
      "cetas-run: enter one task line on stdin and press Enter (or pass -- \"<task>\"); see cetas-run --help.\n",
    )
  }
  action
}
