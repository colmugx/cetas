import { describe, expect, test } from "bun:test";
import { formatProgramStatus } from "@earendil-works/pi-tui";
import { classifyRequestStatus, projectProgramStatus, type ProgramStatusSource } from "./program-status.ts";

const idle: ProgramStatusSource = {
  appState: "ready",
  operationBusy: false,
  commandBusy: false,
  turnActive: false,
  pendingQuestions: 0,
  pendingAuth: 0,
  stopping: false,
};

describe("OSC 7501 Cetas one-root program status", () => {
  test("initialization, readiness, running and closing", () => {
    expect(projectProgramStatus({ ...idle, appState: undefined })).toEqual({
      state: "working", app: "cetas", message: "Starting",
    });
    expect(projectProgramStatus(idle)).toEqual({ state: "idle", app: "cetas" });
    expect(projectProgramStatus({ ...idle, operationBusy: true }).state).toBe("working");
    expect(projectProgramStatus({ ...idle, turnActive: true }).state).toBe("working");
    expect(projectProgramStatus({ ...idle, commandBusy: true }).state).toBe("working");
    expect(projectProgramStatus({ ...idle, stopping: true })).toEqual({ state: "clear" });
  });

  test("waiting input outranks a still-running turn", () => {
    expect(projectProgramStatus({ ...idle, appState: "running", operationBusy: true, pendingQuestions: 1 }))
      .toEqual({ state: "blocked", app: "cetas", kind: "question", message: "Waiting for your response" });
    expect(projectProgramStatus({ ...idle, pendingQuestions: 2, pendingAuth: 1 }))
      .toEqual({ state: "blocked", app: "cetas", kind: "auth", message: "Waiting for authentication" });
    expect(projectProgramStatus({ ...idle, appState: "needs_setup" }).kind).toBe("auth");
  });

  test("status request classification reads only the event discriminator", () => {
    expect(classifyRequestStatus(JSON.stringify({type:"auth_prompt", secret:"sk-private"}))).toBe("auth");
    expect(classifyRequestStatus(JSON.stringify({type:"ui_request", request:{type:"confirm"}}))).toBe("question");
    expect(classifyRequestStatus("invalid")).toBe("question");
  });

  test("wire contains only fixed, non-sensitive text", () => {
    const wire = formatProgramStatus(projectProgramStatus({...idle, pendingQuestions: 1}));
    expect(wire).toContain("state=blocked");
    expect(wire).not.toContain("/private/");
    expect(wire).not.toContain("sk-");
  });
});
