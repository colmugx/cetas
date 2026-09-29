# Cetas plugin architecture

This document reserves the term **plugin** for runtime-installable Cetas
packages and keeps **extension** as the Posoco composition-time abstraction.

The short rule is:

> **Extensions build Cetas; plugins extend Cetas.**

## Terminology

### Posoco native extension

A Posoco extension is a MoonBit value that implements `@posoco.Extension`
and one or more Posoco port traits. It is selected by a Cetas outlet at build
/ composition time and is compiled into that outlet.

Examples include `posoco-ext-read`, `posoco-ext-mcp`, and
`cetas-ext-forme`.

Native extensions are an implementation mechanism for building Cetas. They
are not end-user installable packages and should not be exposed through a
future `cetas plugin ...` CLI.

### Cetas plugin

A Cetas plugin is a runtime-discoverable package installed into an already
built Cetas product. A plugin does **not** implement `@posoco.Extension`
directly and does not depend on the MoonBit object ABI.

A future plugin package may contribute a deliberately small set of stable
capabilities such as:

- skills,
- tools backed by MCP or another process protocol,
- lifecycle/pipeline hooks through a serialized protocol,
- user commands,
- selected UI contributions.

The plugin capability schema is a Cetas product API. It is intentionally not
a serialized copy of `ExtensionManifest`.

## Boundary

The proposed bridge is a built-in native extension tentatively named
`cetas-ext-plugin-host`.

```text
runtime-installed plugins
        |
        | Cetas plugin protocol
        v
+-------------------------+
| cetas-ext-plugin-host   |   compiled into Cetas
+------------+------------+
             |
             | Posoco ports
             v
+-------------------------+
|      Posoco Agent       |
+-------------------------+
```

The plugin host is a multiplexing adapter. Posoco sees one ordinary native
extension; the host can discover and route contributions from multiple
runtime plugins behind that extension.

This preserves the current Posoco invariant: the core composes known port
providers without learning about installation, marketplaces, trust stores,
package discovery, or plugin lifecycle policy.

## Proposed component split

The implementation should keep product concerns separate rather than growing
one manager object:

- **PluginStore** — install, remove, update, and locate plugin package files.
- **PluginCatalog** — discover manifests and resolve enabled plugins.
- **PluginRuntime** — start/stop external services and dispatch plugin calls.
- **PluginHostExtension** — adapt runtime plugin capabilities into Posoco
  ports.

Only the last component is a Posoco extension.

## Capability mapping

The first implementation should expose only capabilities whose runtime
semantics are stable and naturally multiplexable.

| Cetas plugin capability | Posoco projection |
| --- | --- |
| skill | skills catalog / prompt activation path |
| tool | `ToolProvider` |
| hook | `PipelineHook` |
| command | `CommandPort` |
| selected UI contribution | `UiPort` where a stable mapping exists |

Do not initially expose every Posoco port as a plugin capability. In
particular, `ModelPort` and `SessionStore` have composition/cardinality
semantics that should remain native until a separate runtime contract is
designed.

## Naming rules

1. `posoco-ext-*` and `cetas-ext-*` name native, compile-time MoonBit
   components.
2. Runtime-installed packages are called **plugins**, never extensions.
3. User-facing commands use `cetas plugin ...`; there should be no
   `cetas extension install` command.
4. Documentation should say **native extension** when the distinction matters.
5. A plugin is *adapted by* the plugin host; it is never documented as a
   dynamically loaded Posoco extension.

These rules keep the two extension surfaces independent: Posoco can evolve
its internal port algebra without making every new port part of the public
plugin ABI, while Cetas can evolve plugin distribution and trust policy
without teaching Posoco about product packaging.
