# Native test checklist (historical Alpha guidance)

`cetas-native` now ships in public Cetas releases for macOS Apple Silicon, Linux x64 and Windows x64. The earlier Actions-artifact-only alpha distribution process is retired. For current installation, see [Native README](README.md); the recommended first-choice terminal remains `cetas-js` from npm.

This checklist remains useful for testing a new Native version before trusting it with real work. Shared Cetas/Posoco internals do not mean UI parity, equivalent permissions, or cross-host conversation-resume support.

## Keep test state separate

By default JS, Native, ACP and Run may share `~/.cetas`. When investigating a new Native release or regressions, point Native at an isolated **parent home**:

```sh
mkdir -p "$HOME/cetas-native-test-home"
export CETAS_HOME="$HOME/cetas-native-test-home"
cd /path/to/disposable-git-project
cetas
```

State is under `$CETAS_HOME/.cetas/`, not directly under `$CETAS_HOME`. Do not copy live credentials or session transcripts into the test home; start with a disposable workspace and read-only/interactive permissions.

## Test before relying on it

- Fresh install on a clean machine on each advertised OS/architecture. Check `cetas --version`, terminal restoration, ACP/Run sibling dispatch and Windows DLL adjacency.
- Complete a real provider login and model selection, a streamed answer, a read-only tool call and an approved write tool.
- Test session save/reopen, cancellation and recovery using **disposable** sessions; preserve backups of original transcripts.
- Confirm errors are surfaced without exposing credentials in logs or terminal output.
- If a release fails these checks, stop recommending that version until a fix is published.

CI covers build, Bridge and scripted UI/PTY paths but cannot prove end-to-end operation with every live provider. Report host, version, OS, terminal emulator and redacted reproduction details. Never attach tokens or complete session histories.
