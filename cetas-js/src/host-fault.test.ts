import { describe, expect, test } from "bun:test";

import { makeUnhandledFaultHandler } from "./host-fault.ts";

describe("unhandled host faults", () => {
  test("a live surface is stopped and the process exits instead of continuing the turn", () => {
    const calls: string[] = [];
    const handle = makeUnhandledFaultHandler({
      report: (kind: string) => {
        calls.push(`report:${kind}`);
        return "crash recorded";
      },
      stopSurface: (outputBroken: boolean) => calls.push(`stop:${outputBroken}`),
      releaseResources: () => calls.push("release"),
      writeDiagnostic: (notice: string) => calls.push(`diagnostic:${notice}`),
      exitFatal: () => calls.push("exit:1"),
    });

    handle("unhandled rejection", new TypeError("null.length"));

    expect(calls).toEqual([
      "report:unhandled rejection",
      "stop:false",
      "release",
      "diagnostic:crash recorded",
      "exit:1",
    ]);
  });

  test("reentrant and repeated faults neither log nor clean up twice", () => {
    const calls: string[] = [];
    let nested = false;
    const handle = makeUnhandledFaultHandler({
      report: () => {
        calls.push("report");
        if (!nested) {
          nested = true;
          handle("uncaught exception", new Error("nested"));
        }
        return "notice";
      },
      stopSurface: () => calls.push("stop"),
      releaseResources: () => calls.push("release"),
      writeDiagnostic: () => calls.push("diagnostic"),
      exitFatal: () => calls.push("exit:1"),
    });
    handle("unhandled rejection", new Error("first"));
    handle("uncaught exception", new Error("later"));
    expect(calls).toEqual(["report", "stop", "release", "diagnostic", "exit:1"]);
  });

  test("a broken output pipe is not used for teardown or another diagnostic", () => {
    const calls: string[] = [];
    const handle = makeUnhandledFaultHandler({
      report: () => { calls.push("report"); return "notice"; },
      stopSurface: (broken) => calls.push(`stop:${broken}`),
      releaseResources: () => calls.push("release"),
      writeDiagnostic: () => calls.push("diagnostic"),
      exitFatal: () => calls.push("exit:1"),
    });
    handle("uncaught exception", Object.assign(new Error("write EPIPE"), { code: "EPIPE" }));
    expect(calls).toEqual(["report", "stop:true", "release", "exit:1"]);
  });

  test("a pipe failure during cleanup suppresses subsequent terminal output", () => {
    let diagnosed = false;
    let exited = false;
    const handle = makeUnhandledFaultHandler({
      report: () => "notice",
      stopSurface: () => { throw Object.assign(new Error("write EPIPE"), { code: "EPIPE" }); },
      releaseResources: () => {},
      writeDiagnostic: () => { diagnosed = true; },
      exitFatal: () => { exited = true; },
    });
    handle("unhandled rejection", new Error("first"));
    expect(diagnosed).toBe(false);
    expect(exited).toBe(true);
  });

  test("a failed crash logger still leaves the original error in the diagnostic", () => {
    let diagnostic = "";
    const handle = makeUnhandledFaultHandler({
      report: () => { throw new Error("disk full"); },
      stopSurface: () => {},
      releaseResources: () => {},
      writeDiagnostic: (notice) => { diagnostic = notice; },
      exitFatal: () => {},
    });
    handle("unhandled rejection", new TypeError("null.length"));
    expect(diagnostic).toContain("TypeError: null.length");
    expect(diagnostic).toContain("disk full");
  });

  for (const failedStep of ["report", "stop", "release", "diagnostic"]) {
    test(`a failing ${failedStep} cannot prevent remaining cleanup or exit`, () => {
      const calls: string[] = [];
      const step = (name: string) => {
        calls.push(name);
        if (name === failedStep) throw new Error(`${name} failed`);
      };
      const handle = makeUnhandledFaultHandler({
        report: () => { step("report"); return "notice"; },
        stopSurface: () => step("stop"),
        releaseResources: () => step("release"),
        writeDiagnostic: () => step("diagnostic"),
        exitFatal: () => step("exit:1"),
      });
      expect(() => handle("uncaught exception", new Error("first"))).not.toThrow();
      expect(calls).toContain("stop");
      expect(calls).toContain("release");
      expect(calls.at(-1)).toBe("exit:1");
    });
  }
});
