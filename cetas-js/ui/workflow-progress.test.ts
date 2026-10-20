import { expect, test } from "bun:test";
import { WorkflowProgress } from "./workflow-progress.ts";

function view(phase: string, uncertain = false) {
  return { board: { revision: "1" }, workflow: { phase: "Paused" },
    executions: [{ task_id: "task", attempt_id: "attempt", execution_id: "execution", phase }],
    operation_active: false, unresolved: false, mutation_uncertain: uncertain };
}

test("progress reads fresh authoritative status until actual execution settles", async () => {
  let reads = 0;
  const rendered: unknown[] = [];
  const settled = Promise.withResolvers<void>();
  const progress = new WorkflowProgress(async () => view(++reads === 1 ? "Started" : "Settled"), value => {
    rendered.push(value);
    if ((value as ReturnType<typeof view>).executions[0]!.phase === "Settled") settled.resolve();
  }, () => settled.reject(new Error("unexpected status failure")), 1);
  try {
    progress.observe(view("Reserved"));
    await settled.promise;
    expect(reads).toBe(2);
    expect(rendered).toHaveLength(2);
  } finally { progress.close(); }
});

test("progress close drops an in-flight read without cancelling actual execution", async () => {
  const entered = Promise.withResolvers<void>();
  const response = Promise.withResolvers<unknown>();
  let renders = 0;
  let errors = 0;
  const progress = new WorkflowProgress(async () => { entered.resolve(); return response.promise; }, () => renders++, () => errors++, 1);
  progress.observe(view("Started"));
  await entered.promise;
  progress.close();
  response.resolve(view("Settled"));
  await response.promise;
  await Promise.resolve();
  expect(renders).toBe(0);
  expect(errors).toBe(0);
});

test("status failure is surfaced and never retries an execution or mutation", async () => {
  const failed = Promise.withResolvers<void>();
  let reads = 0;
  const progress = new WorkflowProgress(async () => { reads++; throw new Error("private detail"); }, () => failed.reject(new Error("unexpected render")), () => failed.resolve(), 1);
  try {
    progress.observe(view("Started"));
    await failed.promise;
    expect(reads).toBe(1);
  } finally { progress.close(); }
});

test("uncertain status does not arm polling or automatic reconciliation", () => {
  let reads = 0;
  const progress = new WorkflowProgress(async () => { reads++; return view("Settled"); }, () => {}, () => {}, 1);
  progress.observe(view("Started", true));
  progress.close();
  expect(reads).toBe(0);
});

test("a newer active observation survives an older in-flight status read", async () => {
  const entered = Promise.withResolvers<void>();
  const old = Promise.withResolvers<unknown>();
  const settled = Promise.withResolvers<void>();
  let reads = 0;
  const rendered: unknown[] = [];
  const progress = new WorkflowProgress(async () => {
    if (++reads === 1) { entered.resolve(); return old.promise; }
    return view("Settled");
  }, value => { rendered.push(value); settled.resolve(); }, () => settled.reject(new Error("status read failed")), 1);
  try {
    progress.observe(view("Started"));
    await entered.promise;
    progress.observe(view("Settled"));
    progress.observe(view("Reserved"));
    old.resolve(view("Started"));
    await settled.promise;
    expect(reads).toBe(2);
    expect(rendered).toEqual([view("Settled")]);
  } finally { progress.close(); }
});
