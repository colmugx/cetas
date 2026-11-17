///|
/// Parse the trusted pre-ACP commands without I/O. Unknown flags and
/// malformed setup/login invocations never fall through to ACP startup.
pub(all) enum MemohInvocation {
  MemohServe
  MemohSetup(String)
  MemohLogin(String)
  MemohHelp
  MemohVersion
  MemohInvalid(String)
}

///|
pub fn parse_memoh_invocation(argv : Array[String]) -> MemohInvocation {
  match argv {
    [] | ["serve"] => MemohServe
    ["--help"] | ["-h"] | ["help"] => MemohHelp
    ["--version"] | ["version"] => MemohVersion
    ["setup"] => MemohSetup("")
    ["login"] => MemohLogin("")
    ["setup", provider] if !provider.is_empty() && !provider.has_prefix("-") =>
      MemohSetup(provider)
    ["login", provider] if !provider.is_empty() && !provider.has_prefix("-") =>
      MemohLogin(provider)
    _ => MemohInvalid("unknown command or invalid arguments")
  }
}

///|
pub fn memoh_usage() -> String {
  "usage: cetas-memoh [serve | setup [provider] | login [provider] | --help | --version]"
}
