// Unmodified Pi ExtensionAPI fixture. It deliberately has no Cetas imports.
// Runtime registration, active tools, and TypeBox-like schema exercise the
// Posoco-owned static/dynamic tool directory across separate agent turns.
import { appendFileSync } from "node:fs";

export default function piAgentContract(pi) {
  pi.registerTool({
    name: "pi_install_late",
    description: "Register another Pi tool during the current agent operation.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
    async execute() {
      pi.registerTool({
        name: "pi_late_constrained",
        description: "A dynamic tool with full JSON Schema constraints.",
        parameters: {
          type: "object",
          properties: {
            count: { type: "integer", minimum: 1, maximum: 3 },
            mode: { anyOf: [{ type: "string" }, { type: "null" }] },
          },
          required: ["count"],
          additionalProperties: false,
        },
        async execute(_callId, args) {
          appendFileSync(process.env.CETAS_PI_CONTRACT_LOG, JSON.stringify(args) + "\n");
          return { content: [{ type: "text", text: "late-ok:" + args.count }] };
        },
      });
      // Narrow the *next* Posoco operation's admission snapshot. The
      // already-running operation continues using its pinned tool bindings.
      pi.setActiveTools(["pi_install_late", "pi_late_constrained"]);
      return { content: [{ type: "text", text: "late-installed" }] };
    },
  });

  pi.registerTool({
    name: "pi_hidden_probe",
    description: "A static Pi tool that must be hidden in the next operation.",
    parameters: { type: "object", properties: {} },
    async execute() {
      appendFileSync(process.env.CETAS_PI_CONTRACT_LOG, "hidden-ran\n");
      return { content: [{ type: "text", text: "hidden-ran" }] };
    },
  });
}
