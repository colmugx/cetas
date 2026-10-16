import type { Channel, PackageManager } from "../src/app/version.ts";
import { runUpdateCheck, updateInstallCommand } from "../src/app/update-check.ts";
import type { UpdateOverlay } from "./update-picker.ts";
import type { CommandLock } from "./command-lock.ts";

export interface UpdateWorkflowPorts {
  version?: { version: string; channel: Channel; manager: PackageManager };
  home: string;
  lock: CommandLock;
  overlay: Pick<UpdateOverlay, "open">;
  busy(): boolean;
  notice(message: string, isError?: boolean): void;
  install(command: string): void;
  check?: typeof runUpdateCheck;
}

/** Host command workflow; process handoff remains with TerminalShell. */
export class UpdateWorkflow {
  constructor(private readonly ports: UpdateWorkflowPorts) {}

  async run(): Promise<void> {
    const { version: info, lock } = this.ports;
    if (info === undefined) {
      this.ports.notice("/update is unavailable without version info", true);
      return;
    }
    if (this.ports.busy()) {
      this.ports.notice("/update cannot run while an operation is active", true);
      return;
    }
    if (info.channel !== "npm") {
      this.ports.notice(`/update supports the npm channel only (this install is ${info.channel})`);
      return;
    }
    const lease = lock.lease("checking for updates");
    let handedOff = false;
    try {
      const hit = await (this.ports.check ?? runUpdateCheck)({
        home: this.ports.home,
        channel: "npm",
        currentVersion: info.version,
        manager: info.manager,
        bypassCache: true,
      });
      if (hit === undefined) {
        this.ports.notice(`cetas ${info.version} is up to date`);
        return;
      }
      const command = updateInstallCommand(info.manager);
      this.ports.overlay.open(
        info.version,
        hit.latest,
        command,
        (choice) => {
          if (choice === "command") this.ports.notice(`update command: ${command}`);
          if (choice === "update") this.ports.install(command);
        },
        () => lease.release(),
      );
      // Ownership passes to the overlay. Selection and cancellation both close it.
      handedOff = true;
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : String(error);
      this.ports.notice(`/update failed: ${message}`, true);
    } finally {
      if (!handedOff) lease.release();
    }
  }
}
