# Experimental PTC Agent mode

For an isolated preview of the MoonBit \`run_code\` tool, start the Cetas JS
host with \`CETAS_PTC_EXPERIMENTAL=1\`. This mode replaces the compiled
recipe's ordinary tools with a PTC program executor and keeps normal model,
permission, UI and session composition. The toolchain is still owned by the
MBTX extension, not installed by Cetas.

**This is not a production PTC mode.** The Posoco Kernel does not yet issue
individually governed nested tool Effects, so \`ctx.call\` fails closed rather
than performing host tools. The experimental mode is suited to pure MoonBit
program execution only. Do not enable it by default or advertise it as a
replacement for the native editing/search workflow.

PTC-only tool presentation is not guaranteed for extensions dynamically
added after this recipe (e.g., by MCP or Pi integration). The full selection
and bridge must be coordinated at the final agent composition boundary.
