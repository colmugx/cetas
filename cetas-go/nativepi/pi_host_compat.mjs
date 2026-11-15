// Cetas's Pi host module adapter. Pi extensions run inside Bun, but there is
// no second Pi Agent. Only the explicitly bridged host surface is exported.
// Keep real third-party utilities (e.g. typebox) in the npm package graph.
const hostModules = {
  "@earendil-works/pi-tui": `
    export function truncateToWidth(input, width, suffix = "…") {
      if (!Number.isFinite(width) || width <= 0) return "";
      const text = String(input ?? "");
      if (Bun.stringWidth(text) <= width) return text;
      const tail = Bun.stringWidth(suffix) < width ? suffix : "";
      let result = "";
      for (const codepoint of text) {
        if (Bun.stringWidth(result + codepoint + tail) > width) break;
        result += codepoint;
      }
      return result + tail;
    }
    // A headless Pi guest cannot create a terminal-controlled component.
    // Exports satisfy static imports, but actual UI use must be explicit.
    function unavailable() {
      throw new Error("Pi terminal components require a native UI adapter; Bun guest is headless");
    }
    export class Box { constructor() { unavailable(); } }
    export class Text { constructor() { unavailable(); } }
  `,
  "@earendil-works/pi-coding-agent": `
    import { join } from "node:path";
    export function getAgentDir() {
      const home = process.env.CETAS_HOME || process.env.HOME || process.env.USERPROFILE;
      if (!home) throw new Error("Cetas home is unavailable to the Pi guest");
      return join(home, ".cetas");
    }
    export function buildSessionContext(branch) {
      if (!Array.isArray(branch)) throw new Error("Pi session branch was not supplied by the Cetas host");
      return { messages: branch.filter(entry => entry && typeof entry === "object") };
    }
    export async function resizeImage() {
      throw new Error("Pi resizeImage is not exposed by the Cetas native Pi host");
    }
  `,
};

// Only Pi-host-owned import names are virtualized. Do not shadow Node
// builtins or application dependencies, and never load a complete JS Agent
// kernel in this optional subprocess.
export function installPiHostCompat() {
  Bun.plugin({
    name: "cetas-pi-host",
    setup(build) {
      build.onResolve(
        { filter: /^@earendil-works\/pi-(?:tui|coding-agent)$/ },
        args => ({ path: args.path, namespace: "cetas-pi-host" }),
      );
      build.onLoad(
        { filter: /.*/, namespace: "cetas-pi-host" },
        args => {
          const contents = hostModules[args.path];
          if (contents === undefined) throw new Error("Unsupported Pi host module " + args.path);
          return { contents, loader: "js" };
        },
      );
    },
  });
}
