# Shared CLI translations

`i18n/catalog.json` is the single source of terminal-interface translations
for `cetas-js` (pi-tui) and `cetas-go` (Bubble Tea). Add a semantic key to
**both** locale maps; do not maintain host-specific copies.

From the repository root:

```sh
go run i18n/generate.go
go run i18n/generate.go -check
```

The generator emits `cetas-js/src/i18n/generated.ts` and
`cetas-go/internal/i18n/generated.go`. Generated files are committed so Go
builds do not depend on Bun, JSON parsing, or the generator at runtime.

## Language

Both CLI hosts honor the following order:

1. `cetas --lang zh-CN` / `cetas-js --lang zh-CN`
2. `CETAS_LANG=zh-CN`
3. `~/.cetas/settings.json`: `{"ui":{"locale":"zh-CN"}}`
4. System locale (`LANG`, `LC_MESSAGES`, `LC_ALL`), where available
5. `en-US` fallback

Supported translations: `en-US` and `zh-CN`. Language-family tags such as
`zh_TW` and `en_GB` normalize to the current supported catalog for their
language. Unsupported explicit choices are reported as configuration errors,
not silently accepted. `auto` delegates to the next available source.

Use `/language` to see the active language and `/language zh-CN` to save a
preference in the **shared** settings file. Restart the terminal app after
changing it. Already-persisted transcripts and tool output remain byte-for-byte
unchanged; only product-owned presentation text is localized.

## Boundaries

Keep command IDs, parameter names, JSON fields, event names, permission modes,
provider/model identifiers, stored transcript text and LLM-generated content
stable. Localize UI captions/help/status and product-owned error messages
at their host presentation boundaries. When a Posoco extension provides
a command description without a known Cetas key, keep its original text.

The Go and TypeScript hosts only read precompiled translation tables. Neither
calls the MoonBit bridge to format strings during terminal rendering.
