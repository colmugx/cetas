///|
#cfg(target="native")
fn mint_login_device_id() -> String raise @posoco.CommandError {
  // UUID v4 shape, shared with cetas-js's crypto.randomUUID device file.
  let bytes = match @env.rand(16) {
    Some(bytes) if bytes.length() == 16 => bytes
    _ =>
      raise @posoco.CommandError::ExecutionFailed(
        "Cannot mint persistent login device id",
      )
  }
  let hex = "0123456789abcdef"
  let out = StringBuilder()
  for i in 0..<16 {
    if i == 4 || i == 6 || i == 8 || i == 10 {
      out.write_string("-")
    }
    let byte = if i == 6 {
      (bytes[i].to_int() & 15) | 64
    } else if i == 8 {
      (bytes[i].to_int() & 63) | 128
    } else {
      bytes[i].to_int()
    }
    out.write_string(hex[byte >> 4:(byte >> 4) + 1].to_owned())
    out.write_string(hex[byte & 15:(byte & 15) + 1].to_owned())
  }
  out.to_string()
}

///|
/// Authenticate without constructing an Agent or generating a model turn.
#cfg(target="native")
pub async fn run_login(
  home~ : String,
  provider~ : String,
  note~ : async (String) -> Unit noraise,
) -> Unit {
  with_terminal_auth(note~, body=async fn(interaction, prompt) {
    run_login_with_interactions(
      home~,
      provider~,
      note~,
      fs=@workspace.NativeWorkspaceFs(),
      interaction~,
      prompt~,
      mint_device_id=mint_login_device_id,
    )
  })
}
