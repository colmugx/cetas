///|
/// Run usage is shared by help and startup/argument failures.
pub fn run_usage() -> String {
  "usage: cetas-run [--model <provider/model>] [--effort <level>] [--session <id>] [--yolo | --permission <readonly|workspace_write|interactive|auto>] [--stream] [--verbose] [--show-thinking] [--jsonl] [-- \"<task>\"]\n"
}

///|
/// Static help: no filesystem, stdin, or provider discovery is needed.
pub fn invocation_help() -> String {
  (
    $| \{run_usage()} +
    $|        cetas-run --login [provider]
    $|        cetas-run --help | -h | --version
    $| Run exactly one user turn. Put task text after -- (not positionally),
    $| or pipe/read one line on stdin. --model and --effort are run-scoped.
    $| --session resumes a session; otherwise a fresh session is created.
    $| --yolo runs unattended without terminal UI; --permission selects the posture.
    $| Text stdout is answer-only; --stream emits live answer deltas.
    $| --verbose logs events and --show-thinking prints reasoning on stderr.
    $| --jsonl takes precedence: stdout is the JSONL event stream.
    $| CETAS_HOME overrides the platform user home (not the .cetas directory).
    $| Normal startup creates missing .cetas/settings.json with empty providers;
    $| existing settings are never overwritten by bootstrap. Login is standalone.
    $| Credentials are shared with Cetas: if already logged in, retry your task.
    $| Otherwise, native: run cetas-run --login (provider is optional).
    $| Wasm/MoonX: use Cetas /login with the same home and grant sandbox access.
    $| Alternatively configure providers manually in .cetas/settings.json.
    $| Help/version do not write config, read stdin, or contact providers.
    $| Exit codes: 0 success, 1 failed turn, 2 startup/usage/login failure.
  )
}

///|
/// Short first-run guide. The caller sends this only to stderr.
pub fn onboarding_guide(path : String, native~ : Bool) -> String {
  let login = if native {
    "cetas-run: credentials are shared with Cetas; if already logged in, retry your task. Otherwise run cetas-run --login.\n"
  } else {
    "cetas-run: credentials are shared with Cetas; if already logged in, retry here. Otherwise use Cetas /login; use the same CETAS_HOME and grant sandbox access to that home.\n"
  }
  "cetas-run: created minimal settings at " +
  path +
  "\n" +
  login +
  "cetas-run: run cetas-run -- \"hello\", or enter one task line on stdin and press Enter; see cetas-run --help.\n" +
  "cetas-run: manual fallback: configure the providers object in that file manually.\n"
}
