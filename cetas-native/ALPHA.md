# cetas-native Alpha candidate

This is an **opt-in, experimental** native terminal frontend built with Go,
Bubble Tea v2 and the MoonBit/Posoco runtime. It is **not** an upgrade of
`cetas-js` and does not implement Pi or Node/Bun-only extensions. Features
can differ in both directions.

## Supported platforms and distribution

The dedicated native workflow currently validates Linux and macOS on its
GitHub-hosted runner architectures. Windows is not part of this Alpha.

To make a candidate without publishing a release:

1. In GitHub Actions, choose **cetas-native Go/Bubble Tea validation**.
2. Select the intended branch/commit and choose **Run workflow**.
3. Wait for both platform jobs to pass. Download the
   `cetas-native-alpha-<OS>-<architecture>` artifacts from that run.
4. Extract the archive matching your OS and CPU. Verify the adjacent
   `.sha256` file using `shasum -a 256 -c <file>.sha256` from the
   directory containing the archive, then run `./cetas-native --version`.

These are short-lived **GitHub Actions artifacts**, not signed public release
assets. The artifacts contain the native executable and this document.
Recipients do **not** need Go, MoonBit, Bun or Node to execute the binary;
they may still need platform system libraries normally required by cgo.

## Protect existing JS sessions and credentials

Both frontends normally use the same `~/.cetas` directory for durable state.
For this Alpha, **do not run Native against your existing production
`cetas-js` state**, especially when testing rewind or cancellation.

Use a new isolated parent-home directory:

```sh
mkdir -p "$HOME/cetas-native-alpha-home"
export CETAS_HOME="$HOME/cetas-native-alpha-home"
cd /path/to/a/disposable-git-project
/path/to/cetas-native
```

State will be stored beneath
`$HOME/cetas-native-alpha-home/.cetas/`, **not** directly in
`$CETAS_HOME`. Configure a test provider/account inside the isolated state.
Do not copy live credential files or production session JSONL files into it.
**Current first-run limitation:** a newly empty `CETAS_HOME` cannot
currently reach the native `/login` UI. The core rejects composition when
there is no configured provider, and the Native Harness answers commands with
a setup error in that state. For internal testing, preconfigure a *throwaway*
provider in the isolated `$CETAS_HOME/.cetas/settings.json` and its
credential store according to [provider configuration](../docs/configuration.md),
or initialize that isolated home through an existing supported Cetas client.
Do not copy the real production home. Native first-run onboarding is a
**release blocker for self-service external Alpha** until it can collect a
provider credential before the Agent is composed.

Use a clean Git worktree for permission and tool-write testing. Start with
interactive or read-only permissions; do not use `/permission yolo` in Alpha.

## Must-pass checks before inviting external testers

- Fresh install on a **clean machine** for every advertised OS/architecture,
  not just an Actions build runner. Check executable startup, exit and terminal
  restoration.
- Real provider credential flow (API key and/or OAuth), model/effort choice,
  one streamed answer, one read-only tool call and one approved write tool.
- Persist and reopen a conversation across process restart; test session
  switching and rewind against **disposable data**, with the original JSONL
  backed up and compared. Verify Ctrl+C and Esc cancellation do not hang.
- Confirm errors are displayed and no credentials or secret-input values
  appear in terminal output/logs.
- Make an explicit decision on crash-report/log handling, incident triage,
  and ability to stop distributing a bad build.

If a check fails, hold external distribution. The current automated PTY tests
exercise terminal ownership and scripted UI input; they do not establish
end-to-end correctness with a real provider.

## Feedback

Include OS and architecture, build commit, terminal emulator, reproducible
steps, and redacted output. Never include API keys, OAuth tokens, or complete
session histories in public issues. The stable `cetas-js` installation remains
the fallback.
