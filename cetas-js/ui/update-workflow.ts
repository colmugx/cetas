import type { Channel, PackageManager } from "../src/app/version.ts";
import { runUpdateCheck, updateInstallCommand } from "../src/app/update-check.ts";
import type { UpdateOverlay } from "./update-picker.ts";
import type { CommandRunner } from "./command-runner.ts";

export interface UpdateWorkflowPorts {
  version?: { version: string; channel: Channel; manager: PackageManager };
  home: string;
  commands: CommandRunner;
  overlay: Pick<UpdateOverlay, "choose">;
  busy(): boolean;
  notice(message: string, isError?: boolean): void;
  install(command: string): void;
  check?: typeof runUpdateCheck;
}

export class UpdateWorkflow {
  constructor(private readonly ports: UpdateWorkflowPorts) {}
  async run(): Promise<void> {
    const { version: info } = this.ports;
    if (info === undefined) { this.ports.notice("/update is unavailable without version info", true); return; }
    if (this.ports.busy()) { this.ports.notice("/update cannot run while an operation is active", true); return; }
    if (info.channel !== "npm") {
      this.ports.notice(`/update supports the npm channel only (this install is ${info.channel})`);
      return;
    }
    try {
      await this.ports.commands.run("checking for updates", async signal => {
        const hit = await (this.ports.check ?? runUpdateCheck)({
          home: this.ports.home, channel: "npm", currentVersion: info.version,
          manager: info.manager, bypassCache: true,
        });
        if (signal.aborted) return;
        if (hit === undefined) { this.ports.notice(`cetas ${info.version} is up to date`); return; }
        const installCommand = updateInstallCommand(info.manager);
        const choice = await this.ports.overlay.choose(info.version, hit.latest, installCommand, signal);
        if (signal.aborted) return;
        if (choice === "command") this.ports.notice(`update command: ${installCommand}`);
        if (choice === "update") this.ports.install(installCommand);
      });
    } catch (error: unknown) {
      this.ports.notice(`/update failed: ${error instanceof Error ? error.message : String(error)}`, true);
    }
  }
}
